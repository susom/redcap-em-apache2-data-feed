WITH
    pat_map AS
        (
        SELECT
            rsr.redcap_record_id AS redcap_record_id,
            DATE(rsr.dt1) AS enroll_date,
            pat_map.mrn AS mrn,
            pat_map.pat_map_id AS pat_map_id,
            pat_map.pat_name AS pat_name,
            pat_map.first_name AS first_name,
            pat_map.last_name AS last_name,
            pat_map.birth_date AS birth_date
        FROM `som-rit-phi-starr-tools-prod.stride.pat_map` AS pat_map
            RIGHT JOIN EXTERNAL_QUERY('us.starrapi',
                '''select
                        r.starr_record_id as starr_record_id,
                        r.redcap_record_id as redcap_record_id,
                        qp.dt1 as dt1
                    from REDCAP_STARR_RECORD as r
                    join REDCAP_STARR_QUERY_PARAMS as qp
                      on r.redcap_record_id = qp.redcap_record_id
                    where r.link_id = ? and r.status_code = 'A' and qp.link_id = ? ''') AS rsr
                ON pat_map.mrn = rsr.starr_record_id
        ),
    encounter AS
        (
        SELECT
            pat_map.redcap_record_id AS redcap_record_id,
            pat_map.mrn AS mrn,
            enc.pat_map_id AS pat_map_id,
            enc.pat_enc_csn_id AS pat_enc_csn_id,
            pat_map.birth_date AS birth_date,
            pat_map.enroll_date AS enroll_date,
            CASE
                WHEN enc.adt_arrival_time IS NULL THEN enc.hosp_admsn_time
                WHEN DATETIME_DIFF(DATETIME(enc.adt_arrival_time), DATETIME(enc.hosp_admsn_time), SECOND) < 0 THEN enc.adt_arrival_time
                ELSE enc.hosp_admsn_time
            END
            AS earliest_time,
            enc.hosp_admsn_time AS hosp_admsn_time,
            enc.adt_arrival_time AS adt_arrival_time,
            enc.hosp_dischrg_time AS discharge_time
        FROM `som-rit-phi-starr-tools-prod.stride.shc_encounter` AS enc
            LEFT JOIN pat_map AS pat_map
        ON enc.pat_map_id = pat_map.pat_map_id
        WHERE
            enc_type = 'Hospital Encounter'
          AND pt_class IN ('Emergency Services', 'Observation', 'Inpatient')
          AND appt_type IN ('Admission (Admission)', 'Admission (Discharged)')
          AND hosp_admsn_time IS NOT NULL
          AND hosp_dischrg_time IS NOT NULL
          AND
            (
            SAFE.DATE_DIFF(DATE(enroll_date), DATE(adt_arrival_time), DAY) >= 0
           OR
            SAFE.DATE_DIFF(DATE(enroll_date), DATE(hosp_admsn_time), DAY) >= 0
            )
          AND SAFE.DATE_DIFF(DATE(enroll_date), DATE(hosp_dischrg_time), DAY) <= 0
        ),
    adt AS
        (
        SELECT
            enc.redcap_record_id AS redcap_record_id,
            enc.pat_map_id AS pat_map_id,
            clarity_adt.pat_enc_csn_id AS pat_enc_csn_id,
            clarity_adt.event_time AS event_time,
            clarity_adt.pat_lvl_of_care_c AS level_of_care
        FROM `som-rit-phi-starr-prod.shc_clarity_filtered_latest.clarity_adt` AS clarity_adt
            INNER JOIN encounter AS enc
        ON clarity_adt.pat_enc_csn_id = enc.pat_enc_csn_id
        ORDER BY SAFE_CAST(redcap_record_id AS NUMERIC), event_time ASC
            ),
        adt_physical AS
        (
        SELECT
            enc.redcap_record_id AS redcap_record_id,
            enc.pat_map_id AS pat_map_id,
            shc_adt.pat_enc_csn_id AS pat_enc_csn_id,
            shc_adt.event_time AS event_time,
            CASE
                WHEN
                department_name IN ('D2ICU-SURGE', 'E2-ICU', 'E29-ICU', 'J4', 'K4', 'L4', 'M4', 'VCP CCU 1', 'VCP CCU 2', 'VC CRITICAL CARE SPECIALTY', 'VCP SURGE PACU')
                OR pat_service IN ('Critical Care', 'Neurocritical Care', 'Cardiovascular ICU', 'Emergency Critical Care')
                OR pat_lv_of_care = 'Critical Care'
                THEN '8'
                ELSE '99'
            END
            AS level_of_care
        FROM `som-rit-phi-starr-tools-prod.stride.shc_adt` AS shc_adt
        INNER JOIN encounter AS enc
            ON shc_adt.pat_enc_csn_id = enc.pat_enc_csn_id
        ORDER BY SAFE_CAST(redcap_record_id AS NUMERIC), event_time ASC
        ),
    adt_icu AS
        (
        SELECT * FROM adt WHERE level_of_care = '8'
        UNION DISTINCT
        SELECT * FROM adt_physical WHERE level_of_care = '8'
        ORDER BY SAFE_CAST(redcap_record_id AS NUMERIC)
        ),
    icu_admit AS
        (
        SELECT
            adt_icu.redcap_record_id AS redcap_record_id,
            adt_icu.pat_map_id AS pat_map_id,
            adt_icu.pat_enc_csn_id AS pat_enc_csn_id,
            MIN(event_time) AS icu_admit_dttm,
        FROM adt_icu
        GROUP BY redcap_record_id, pat_enc_csn_id, pat_map_id
        ORDER BY SAFE_CAST(redcap_record_id AS NUMERIC)
        ),
    icu_age AS
        (
        SELECT
            pat_map.redcap_record_id AS redcap_record_id,
            pat_map.pat_map_id AS pat_map_id,
            SAFE.DATE_DIFF(SAFE.DATE(icu_admit.icu_admit_dttm), SAFE.DATE(pat_map.birth_date), YEAR) AS age,
        FROM pat_map AS pat_map
        INNER JOIN icu_admit AS icu_admit
            ON pat_map.redcap_record_id = icu_admit.redcap_record_id
        ORDER BY SAFE_CAST(redcap_record_id AS NUMERIC)
        ),
    fio2 AS
        (
        SELECT
            icu_admit.redcap_record_id AS redcap_record_id,
            icu_admit.pat_map_id AS pat_map_id,
            icu_admit.pat_enc_csn_id AS pat_enc_csn_id,
            flow.meas_value AS meas_value,
            flow.row_disp_name AS row_disp_name,
            CASE
                WHEN SAFE_CAST(meas_value AS DECIMAL) > 100 THEN NULL
                WHEN SAFE_CAST(meas_value AS DECIMAL) >= 21 THEN SAFE_CAST(meas_value AS DECIMAL) / 100
                WHEN SAFE_CAST(meas_value AS DECIMAL) <= 1 AND SAFE_CAST(meas_value AS DECIMAL) >= 0.21 THEN SAFE_CAST(meas_value AS DECIMAL)
                ELSE NULL
            END
            AS value
        FROM `som-rit-phi-starr-tools-prod.stride.rit_flowsheet` AS flow
        INNER JOIN icu_admit AS icu_admit
            ON flow.pat_map_id = icu_admit.pat_map_id
        WHERE
            row_disp_name IN ('FiO2 (%)', 'O2 % Concentration')
            AND SAFE.DATE_DIFF(flow.recorded_time, icu_admit.icu_admit_dttm, SECOND) >= 0
            AND SAFE.DATE_DIFF(flow.recorded_time, DATETIME_ADD(icu_admit.icu_admit_dttm, INTERVAL 24 HOUR), SECOND) <= 0
        ),
    fio2_max AS
        (
        SELECT
            redcap_record_id,
            MAX(CASE WHEN fio2.row_disp_name IN ('FiO2 (%)', 'O2 % Concentration') THEN SAFE_CAST(fio2.value AS DECIMAL) END) apache2_fio2_max
        FROM fio2
        GROUP BY redcap_record_id
        ),
    vitals AS
        (
        SELECT
            icu_admit.redcap_record_id AS redcap_record_id,
            icu_admit.pat_map_id AS pat_map_id,
            icu_admit.pat_enc_csn_id AS pat_enc_csn_id,
            flow.row_disp_name AS row_disp_name,
            flow.meas_value AS meas_value
        FROM `som-rit-phi-starr-tools-prod.stride.rit_flowsheet` AS flow
        INNER JOIN icu_admit AS icu_admit
            ON flow.pat_map_id = icu_admit.pat_map_id
        WHERE
            flow.row_disp_name IN
                (
                'Temp (in Celsius)',						                            -- temperature
                'MAP', 'Mean Arterial Pressure', 'Mean Arterial Pressure (Calculated)', -- MAP
                'Pulse', 'Heart Rate', 'HR', 						                    -- heart rate
                'Resp',                              	                                -- respiratory rate
                'Glasgow Coma Scale Score', 'GCS', 'GCS Score'                          -- GCS
                )
          AND SAFE.DATE_DIFF(flow.recorded_time, icu_admit.icu_admit_dttm, SECOND) >= 0
          AND SAFE.DATE_DIFF(flow.recorded_time, DATETIME_ADD(icu_admit.icu_admit_dttm, INTERVAL 24 HOUR), SECOND) <= 0
          AND SAFE_CAST(flow.meas_value AS DECIMAL) >= 0
          AND SAFE_CAST(flow.meas_value AS DECIMAL) < 9999999
          AND SAFE_CAST(flow.meas_value AS DECIMAL) IS NOT NULL -- checks if meas_value column contains a number
                                                                -- instead of dropping nonnumeric meas_value rows, consider using regex instead
        ),
    vitals_minmax AS
        (
        SELECT
            vitals.redcap_record_id AS redcap_record_id,
            MIN(CASE WHEN vitals.row_disp_name IN ('Temp (in Celsius)') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_temp_min,
            MAX(CASE WHEN vitals.row_disp_name IN ('Temp (in Celsius)') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_temp_max,
            MIN(CASE WHEN vitals.row_disp_name IN ('MAP', 'Mean Arterial Pressure', 'Mean Arterial Pressure (Calculated)') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_map_min,
            MAX(CASE WHEN vitals.row_disp_name IN ('MAP', 'Mean Arterial Pressure', 'Mean Arterial Pressure (Calculated)') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_map_max,
            MIN(CASE WHEN vitals.row_disp_name IN ('Pulse', 'Heart Rate', 'HR') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_hr_min,
            MAX(CASE WHEN vitals.row_disp_name IN ('Pulse', 'Heart Rate', 'HR') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_hr_max,
            MIN(CASE WHEN vitals.row_disp_name IN ('Resp') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_rr_min,
            MAX(CASE WHEN vitals.row_disp_name IN ('Resp') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_rr_max,
            MIN(CASE WHEN vitals.row_disp_name IN ('Glasgow Coma Scale Score', 'GCS', 'GCS Score') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_gcs_min,
            MAX(CASE WHEN vitals.row_disp_name IN ('Glasgow Coma Scale Score', 'GCS', 'GCS Score') THEN SAFE_CAST(vitals.meas_value AS DECIMAL) END) apache2_gcs_max
        FROM vitals AS vitals
        GROUP BY redcap_record_id
        ),
    labs AS
        (
        SELECT
            icu_admit.redcap_record_id AS redcap_record_id,
            icu_admit.pat_map_id AS pat_map_id,
            icu_admit.pat_enc_csn_id AS pat_enc_csn_id,
            labs.group_lab_name AS group_lab_name,
            labs.lab_name AS lab_name,
            labs.base_name AS base_name,
            labs.ord_num_value AS ord_num_value,
            CASE
                WHEN lab_name IN ('Sodium',
                                  'Sodium (CIRC), ISTAT',
                                  'Sodium (Manual Entry) See EMR for details',
                                  'Sodium, ISTAT',
                                  'Sodium, Ser/Plas',
                                  'Sodium, Whole Blood',
                                  'Sodium, whole blood, ePOC') THEN 'Na'
                WHEN lab_name IN ('Potassium, Whole Bld',
                                  'Potassium, whole blood, ePOC',
                                  'Potassium',
                                  'Potassium, ISTAT',
                                  'Potassium, serum/plasma',
                                  'Potassium (Manual Entry) See EMR for details',
                                  'Potassium, Ser/Plas') THEN 'K'
                WHEN lab_name IN ('CREATININE',
                                  'Creatinine,ISTAT',
                                  'Creatinine, serum/plasma',
                                  'Creatinine, Serum',
                                  'Creatinine, Serum (Manual Entry) See EMR for details',
                                  'Creatinine',
                                  'Creatinine, Ser/Plas') THEN 'Cr'
                WHEN lab_name IN ('Hct (Est)',
                                  'Hematocrit',
                                  'Hematocrit (Spun)',
                                  'HCT, POC',
                                  'HCT (Manual Entry) See EMR for details',
                                  'Hct, calculated, POC') THEN 'Hct'
                WHEN lab_name IN ('PH (a), ISTAT',
                                  'pH (a)',
                                  'Arterial pH for POC') THEN 'pHa'
                WHEN lab_name IN ('pO2 (a)',
                                  'PO2, ISTAT',
                                  'PO2',
                                  'Arterial pO2 for POC',
                                  'PO2 (a), ISTAT') THEN 'PaO2'
                WHEN
                    base_name IN ('WBC')
                    AND
                    lab_name IN ('WBC Count',
                                 'WBC',
                                 'WBC (Manual Entry) See EMR for details',
                                 'WBC count')
                    AND
                    group_lab_name IN('WBC (MANUAL ENTRY)',
                                     'CBC WITH DIFFERENTIAL/PLATELET (LABCORP)',
                                     'CBC, NO DIFFERENTIAL/PLATELET(LABCORP)',
                                     'CBC',
                                     'CBC with Differential',
                                     'CBC w/DIFF & Slide Review (QUE)',
                                     'CBC in AM',
                                     'CBC WITH DIFF',
                                     'CBC With Diff',
                                     'CBC WITH DIFF AND SLIDE REVIEW',
                                     'CBC With Diff And Slide Review',
                                     'CBC with Diff',
                                     'WBC',
                                     'Complete Blood Count with Differential (Whole Blood)',
                                     'AUTOMATED BLOOD COUNT',
                                     'CBC With Diff  (MMC Protocol)',
                                     'CBC with diff',
                                     'CBC With Diff in AM',
                                     'CBC with Diff and Slide Review',
                                     'CBC: Evening of surgery',
                                     'CBC: POD # 1',
                                     'CBC (MENLO)',
                                     'AUTOMATED BLOOD COUNT (MENLO)',
                                     'CBC WITH MANUAL DIFF (MENLO)',
                                     'CBC (LABCBCO)',
                                     'CBC w/o Diff',
                                     'CBC With Diff (in purple top tube for special hematology)',
                                     'CBC w/Diff (QUE)',
                                     'CBC w/Diff & Slide Review (LC)',
                                     'Complete Blood Count with Differential & Slide Review (Whole Blood)',
                                     'CBC With Diff (LABCBCD)',
                                     'CBC WITH DIFF IN 1 MONTH',
                                     'Complete Blood Count (Whole Blood)',
                                     'CBC w/o diff',
                                     'CBC W/O Diff',
                                     'CBC IN 6 MONTHS',
                                     'CBC- Evening of Surgery',
                                     'CBC POD #1',
                                     'CBC IN 3 MONTHS',
                                     'CBC WITH DIFF IN 6 MONTHS',
                                     'CBC (INCLUDES DIFF/PLT)',
                                     'CBC  [LABCBCO]',
                                     'CBC With Diff  [LABCBCD]',
                                     'CBC  [LABCBCO]  Stanford Drawn',
                                     'CBC/DIFF AMBIGUOUS DEFAULT(977709)',
                                     'CBC w/Diff  (LC)')
                    THEN 'WBC'
            END
            AS lab
        FROM `som-rit-phi-starr-tools-prod.stride.shc_lab_result` AS labs
        INNER JOIN icu_admit AS icu_admit
            ON labs.pat_map_id = icu_admit.pat_map_id
        WHERE
            (
            lab_name IN (
                        'Sodium',
                        'Sodium (CIRC), ISTAT',
                        'Sodium (Manual Entry) See EMR for details',
                        'Sodium, ISTAT',
                        'Sodium, Ser/Plas',
                        'Sodium, Whole Blood',
                        'Sodium, whole blood, ePOC',
                        'Potassium, Whole Bld',
                        'Potassium, whole blood, ePOC',
                        'Potassium',
                        'Potassium, ISTAT',
                        'Potassium, serum/plasma',
                        'Potassium (Manual Entry) See EMR for details',
                        'Potassium, Ser/Plas',
                        'CREATININE',
                        'Creatinine,ISTAT',
                        'Creatinine, serum/plasma',
                        'Creatinine, Serum',
                        'Creatinine, Serum (Manual Entry) See EMR for details',
                        'Creatinine',
                        'Creatinine, Ser/Plas',
                        'Hct (Est)',
                        'Hematocrit',
                        'Hematocrit (Spun)',
                        'HCT, POC',
                        'HCT (Manual Entry) See EMR for details',
                        'Hct, calculated, POC',
                        'PH (a), ISTAT',
                        'pH (a)',
                        'Arterial pH for POC',
                        'pO2 (a)',
                        'PO2, ISTAT',
                        'PO2',
                        'Arterial pO2 for POC',
                        'PO2 (a), ISTAT'
                        )
            OR
            (
            base_name = 'WBC'
            AND lab_name IN (
                            'WBC Count',
                            'WBC',
                            'WBC (Manual Entry) See EMR for details',
                            'WBC count'
                            )
            AND group_lab_name IN (
                                'WBC (MANUAL ENTRY)',
                                'CBC WITH DIFFERENTIAL/PLATELET (LABCORP)',
                                'CBC, NO DIFFERENTIAL/PLATELET(LABCORP)',
                                'CBC',
                                'CBC with Differential',
                                'CBC w/DIFF & Slide Review (QUE)',
                                'CBC in AM',
                                'CBC WITH DIFF',
                                'CBC With Diff',
                                'CBC WITH DIFF AND SLIDE REVIEW',
                                'CBC With Diff And Slide Review',
                                'CBC with Diff',
                                'WBC',
                                'Complete Blood Count with Differential (Whole Blood)',
                                'AUTOMATED BLOOD COUNT',
                                'CBC With Diff  (MMC Protocol)',
                                'CBC with diff',
                                'CBC With Diff in AM',
                                'CBC with Diff and Slide Review',
                                'CBC: Evening of surgery',
                                'CBC: POD # 1',
                                'CBC (MENLO)',
                                'AUTOMATED BLOOD COUNT (MENLO)',
                                'CBC WITH MANUAL DIFF (MENLO)',
                                'CBC (LABCBCO)',
                                'CBC w/o Diff',
                                'CBC With Diff (in purple top tube for special hematology)',
                                'CBC w/Diff (QUE)',
                                'CBC w/Diff & Slide Review (LC)',
                                'Complete Blood Count with Differential & Slide Review (Whole Blood)',
                                'CBC With Diff (LABCBCD)',
                                'CBC WITH DIFF IN 1 MONTH',
                                'Complete Blood Count (Whole Blood)',
                                'CBC w/o diff',
                                'CBC W/O Diff',
                                'CBC IN 6 MONTHS',
                                'CBC- Evening of Surgery',
                                'CBC POD #1',
                                'CBC IN 3 MONTHS',
                                'CBC WITH DIFF IN 6 MONTHS',
                                'CBC (INCLUDES DIFF/PLT)',
                                'CBC  [LABCBCO]',
                                'CBC With Diff  [LABCBCD]',
                                'CBC  [LABCBCO]  Stanford Drawn',
                                'CBC/DIFF AMBIGUOUS DEFAULT(977709)',
                                'CBC w/Diff  (LC)'
                                )
            )
            )
            AND SAFE.DATE_DIFF(labs.taken_time, icu_admit.icu_admit_dttm, SECOND) >= 0
            AND SAFE.DATE_DIFF(labs.taken_time, DATETIME_ADD(icu_admit.icu_admit_dttm, INTERVAL 24 HOUR), SECOND) <= 0
            AND SAFE_CAST(labs.ord_num_value AS DECIMAL) < 9999999
            AND SAFE_CAST(labs.ord_num_value AS DECIMAL) IS NOT NULL -- checks if ord_num_value column is numeric
                                                                     -- instead of dropping nonnumeric ord_num_value rows, consider using regex instead
        ),
    labs_minmax AS
        (
        SELECT
            labs.redcap_record_id AS redcap_record_id,
            MIN(CASE WHEN labs.lab = 'Na' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_na_min,
            MAX(CASE WHEN labs.lab = 'Na' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_na_max,
            MIN(CASE WHEN labs.lab = 'K' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_k_min,
            MAX(CASE WHEN labs.lab = 'K' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_k_max,
            MIN(CASE WHEN labs.lab = 'Cr' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_cr_min,
            MAX(CASE WHEN labs.lab = 'Cr' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_cr_max,
            MIN(CASE WHEN labs.lab = 'Hct' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_hct_min,
            MAX(CASE WHEN labs.lab = 'Hct' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_hct_max,
            MIN(CASE WHEN labs.lab = 'pHa' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_pha_min,
            MAX(CASE WHEN labs.lab = 'pHa' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_pha_max,
            MIN(CASE WHEN labs.lab = 'PaO2' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_pao2_min,
            MAX(CASE WHEN labs.lab = 'PaO2' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_pao2_max,
            MIN(CASE WHEN labs.lab = 'WBC' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_wbc_min,
            MAX(CASE WHEN labs.lab = 'WBC' THEN SAFE_CAST(labs.ord_num_value AS DECIMAL) END) apache2_wbc_max,
        FROM labs AS labs
        GROUP BY redcap_record_id
        ),
    apache2_all AS
        (
        SELECT
            icu_age.redcap_record_id AS redcap_record_id,
            icu_age.age AS tdsr_apache2_age,
            icu_admit.icu_admit_dttm AS tdsr_apache2_icuadmit_dttm,
            vitals_minmax.apache2_temp_min AS tdsr_apache2_temp_min,
            vitals_minmax.apache2_temp_max AS tdsr_apache2_temp_max,
            vitals_minmax.apache2_map_min AS tdsr_apache2_map_min,
            vitals_minmax.apache2_map_max AS tdsr_apache2_map_max,
            vitals_minmax.apache2_hr_min AS tdsr_apache2_hr_min,
            vitals_minmax.apache2_hr_max AS tdsr_apache2_hr_max,
            vitals_minmax.apache2_rr_min AS tdsr_apache2_rr_min,
            vitals_minmax.apache2_rr_max AS tdsr_apache2_rr_max,
            vitals_minmax.apache2_gcs_min AS tdsr_apache2_gcs_min,
            vitals_minmax.apache2_gcs_max AS tdsr_apache2_gcs_max,
            fio2_max.apache2_fio2_max AS tdsr_apache2_fio2_max,
            labs_minmax.apache2_na_min AS tdsr_apache2_na_min,
            labs_minmax.apache2_na_max AS tdsr_apache2_na_max,
            labs_minmax.apache2_k_min AS tdsr_apache2_k_min,
            labs_minmax.apache2_k_max AS tdsr_apache2_k_max,
            labs_minmax.apache2_cr_min AS tdsr_apache2_cr_min,
            labs_minmax.apache2_cr_max AS tdsr_apache2_cr_max,
            labs_minmax.apache2_hct_min AS tdsr_apache2_hct_min,
            labs_minmax.apache2_hct_max AS tdsr_apache2_hct_max,
            labs_minmax.apache2_pha_min AS tdsr_apache2_pha_min,
            labs_minmax.apache2_pha_max AS tdsr_apache2_pha_max,
            labs_minmax.apache2_pao2_min AS tdsr_apache2_pao2_min,
            labs_minmax.apache2_pao2_max AS tdsr_apache2_pao2_max,
            labs_minmax.apache2_wbc_min AS tdsr_apache2_wbc_min,
            labs_minmax.apache2_wbc_max AS tdsr_apache2_wbc_max
        FROM icu_age AS icu_age
        LEFT JOIN icu_admit AS icu_admit
            ON icu_age.redcap_record_id = icu_admit.redcap_record_id
        LEFT JOIN vitals_minmax AS vitals_minmax
            ON icu_age.redcap_record_id = vitals_minmax.redcap_record_id
        LEFT JOIN fio2_max AS fio2_max
            ON icu_age.redcap_record_id = fio2_max.redcap_record_id
        LEFT JOIN labs_minmax AS labs_minmax
            ON icu_age.redcap_record_id = labs_minmax.redcap_record_id
        )
SELECT * FROM apache2_all ORDER BY SAFE_CAST(redcap_record_id AS NUMERIC)
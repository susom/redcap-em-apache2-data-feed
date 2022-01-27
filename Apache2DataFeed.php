<?php
namespace Stanford\Apache2DataFeed;

use REDCap;

require_once "emLoggerTrait.php";

/**
 * Class Apache2DataFeed
 * @
 */
class Apache2DataFeed extends \ExternalModules\AbstractExternalModule {

    use emLoggerTrait;

    public function __construct() {
		parent::__construct();
    }

    /*
     * gets data in CSV format (streamed, not saved as a file) via REDCap to STARR Link
     */
    public function getData($pid, $query_name, $arm, $fields) {
        $rtsl = \ExternalModules\ExternalModules::getModuleInstance('redcap_to_starr_link');
        $rtsl->syncRecords($pid); // sync records
        $response = $rtsl->streamData($pid, $query_name, $arm, $fields); // data retrieval
        return $response;
    }

    /*
     * parses flowlab APACHE II data as CSV into an array
     */
    public function parseFlowLabCSV($flowlab_csv) {
        // parse CSV into array, line by line
        $flowlab_lines = str_getcsv($flowlab_csv, PHP_EOL);

        // remove lines of header data from array
        $header = 'record_id,"tdsr_apache2_age","tdsr_apache2_icuadmit_dttm",' .
            '"tdsr_apache2_temp_min","tdsr_apache2_temp_max",' .
            '"tdsr_apache2_map_min","tdsr_apache2_map_max",' .
            '"tdsr_apache2_hr_min","tdsr_apache2_hr_max",' .
            '"tdsr_apache2_rr_min","tdsr_apache2_rr_max",' .
            '"tdsr_apache2_gcs_min","tdsr_apache2_gcs_max",' .
            '"tdsr_apache2_fio2_max",' .
            '"tdsr_apache2_na_min","tdsr_apache2_na_max",' .
            '"tdsr_apache2_k_min","tdsr_apache2_k_max",' .
            '"tdsr_apache2_cr_min","tdsr_apache2_cr_max",' .
            '"tdsr_apache2_hct_min","tdsr_apache2_hct_max",' .
            '"tdsr_apache2_pha_min","tdsr_apache2_pha_max",' .
            '"tdsr_apache2_pao2_min","tdsr_apache2_pao2_max",' .
            '"tdsr_apache2_wbc_min","tdsr_apache2_wbc_max"';
        while($flowlab_lines[0] !== $header) {
            array_shift($flowlab_lines);
        }
        array_shift($flowlab_lines);

        $flowlab_results = array();
        foreach($flowlab_lines as $line) {
            $result = str_getcsv($line, ',');
            $flowlab_results[] = array(
                "record_id" => $result[0],
                "tdsr_apache2_age" => $result[1],
                "tdsr_apache2_icuadmit_dttm" => $result[2],
                "tdsr_apache2_temp_min" => $result[3],
                "tdsr_apache2_temp_max" => $result[4],
                "tdsr_apache2_map_min" => $result[5],
                "tdsr_apache2_map_max" => $result[6],
                "tdsr_apache2_hr_min" => $result[7],
                "tdsr_apache2_hr_max" => $result[8],
                "tdsr_apache2_rr_min" => $result[9],
                "tdsr_apache2_rr_max" => $result[10],
                "tdsr_apache2_gcs_min" => $result[11],
                "tdsr_apache2_gcs_max" => $result[12],
                "tdsr_apache2_fio2_max" => $result[13],
                "tdsr_apache2_na_min" => $result[14],
                "tdsr_apache2_na_max" => $result[15],
                "tdsr_apache2_k_min" => $result[16],
                "tdsr_apache2_k_max" => $result[17],
                "tdsr_apache2_cr_min" => $result[18],
                "tdsr_apache2_cr_max" => $result[19],
                "tdsr_apache2_hct_min" => $result[20],
                "tdsr_apache2_hct_max" => $result[21],
                "tdsr_apache2_pha_min" => $result[22],
                "tdsr_apache2_pha_max" => $result[23],
                "tdsr_apache2_pao2_min" => $result[24],
                "tdsr_apache2_pao2_max" => $result[25],
                "tdsr_apache2_wbc_min" => $result[26],
                "tdsr_apache2_wbc_max" => $result[27]
            );
        }
        // $this->emDebug($flowlab_results);
        return $flowlab_results;
    }

    /*
     * returns a multidimensional associative array
     */
    public function parseAao2CSV($response_csv) {
        // $this->emDebug("parseAao2CSV(): parsing started...");
        $fio2  = [];
        $pao2  = [];
        $paco2 = [];
        // $this->emDebug("parseAao2CSV(): removing headers...");

        $response_arr = str_getcsv($response_csv, PHP_EOL);
        while($response_arr[0] !== 'redcap_record_id,"type","dttm","value"') {
            // $this->emDebug("removing: " . $response_arr[0]);
            array_shift($response_arr);
        }
        // $this->emDebug("removing: " . $response_arr[0]);
        array_shift($response_arr);

        // $this->emDebug("parseAao2CSV(): headers removed...");
        // $this->emDebug("top of array: " . $response_arr[0]);
        foreach($response_arr as $line) {
            $result = str_getcsv($line, ',');
            $type = $result[1];
            $recording = array(
                               "id"    => $result[0],
                               "dttm"  => $result[2],
                               "value" => $result[3]
                              );
            // $this->emDebug("\$recording: " . implode('|||', $recording));
            switch ($type) {
                case 'FiO2':
                    $fio2[] = $recording;
                    break;
                case 'PaO2':
                    $pao2[] = $recording;
                    break;
                case 'PaCO2':
                    $paco2[] = $recording;
                    break;
                default:
                    $this->emDebug($type . " did not match FiO2, PaO2, or PaCO2");
                    break;
            }
        }

        $aado2_data = [];
        $aado2_data['fio2']  = $fio2;
        $aado2_data['pao2']  = $pao2;
        $aado2_data['paco2'] = $paco2;
        $aado2_data = array(
                            'fio2'  => $fio2,
                            'pao2'  => $pao2,
                            'paco2' => $paco2
                           );
        // $this->emDebug($aado2_data);
        return $aado2_data;
    }

    // returns array of REDCap record IDs based on project
    public function getRecords($pid) {
        $params = array(
            'project_id' => $pid,
            'return_format' => 'json',
            'fields' => array('record_id')
        );

        return REDCap::getData($params);
    }

    // gets most prior value in $array up to date-time as set by $pao2_dttm parameter
    public function mostPriorPaco2($pao2_dttm, $paco2_arr) {
        // create new associative array of objects with date-time on or before $pao2_dttm
        $new_paco2_arr = array_filter($paco2_arr, function ($key) use ($pao2_dttm) {
            return (strtotime($key['dttm']) <= strtotime($pao2_dttm));
        });

        // get most recent value based on $pao2_dttm, return -99 if none found i.e., empty new_paco2_arr
        $latest_paco2 = -99;
        if(count($new_paco2_arr) > 0) {
            usort(
                $new_paco2_arr,
                function($a, $b) {
                    $dttm_1 = strtotime($a['dttm']);
                    $dttm_2 = strtotime($b['dttm']);
                    return $dttm_2 <=> $dttm_1;
                }
            );
            $latest_paco2 = $new_paco2_arr[0]['value'];
        }
        return $latest_paco2;
    }

    // gets most prior value in $fio2_arr up to (but NOT at the same date-time) date-time as set by $pao2_dttm parameter
    public function mostPriorFio2($pao2_dttm, $fio2_arr) {
        // create new associative array of objects with date-time before $pao2_dttm
        $new_fio2_arr = array_filter($fio2_arr, function ($key) use ($pao2_dttm) {
            return (strtotime($key['dttm']) < strtotime($pao2_dttm));
        });

        // get most recent FiO2 value based on $pao2_dttm, return -99 if none found i.e., empty $new_fio2_arr
        $latest_fio2 = -99;
        if(count($new_fio2_arr) > 0) {
            usort(
                $new_fio2_arr,
                function($a, $b) {
                    $dttm_1 = strtotime($a['dttm']);
                    $dttm_2 = strtotime($b['dttm']);
                    return $dttm_2 <=> $dttm_1;
                }
            );
            $latest_fio2 = $new_fio2_arr[0]['value'];
        }
        return $latest_fio2;
    }

    // calculates and returns A-a Gradient
    public function calculateAao2($pao2_val, $paco2_val, $fio2_val) {
        $atm_pressure = 760; // atmospheric pressure
        $h2o_pressure = 47; // water vapor pressure
        $rq = 0.8; // respiratory quotient, constant at 0.8 for all except those with the most extreme and unusual of diets
        return (floatval($fio2_val) * ($atm_pressure - $h2o_pressure) - (floatval($paco2_val) / $rq)) - floatval($pao2_val);
    }

    // returns maximum calculated A-a Gradient
    // returns -99 if no A-a Gradients could be calculated
    public function getAao2Scores($records, $pao2_arr, $paco2_arr, $fio2_arr) {
        $aao2_minmax = [];
        $records_arr = json_decode($records);
        // $this->emDebug($fio2_arr);
        foreach($records_arr as $record) {
            // $this->emDebug('Record_id is: ');
            // $this->emDebug($record->record_id);
            $record_id = $record->record_id;
            $aao2_max = -99;
            $aao2_min = -99;
            $aao2_arr_record = [];
            $fio2_arr_record = array_filter($fio2_arr, function ($key) use ($record_id) {
                return ($key['id'] === $record_id);
            });
            // $this->emDebug('Filtered $fio2_arr_record for ' . $record->record_id . ': ' . count($fio2_arr_record));
            $pao2_arr_record = array_filter($pao2_arr, function ($key) use ($record_id) {
                return ($key['id'] === $record_id);
            });
            $paco2_arr_record = array_filter($paco2_arr, function ($key) use ($record_id) {
                return ($key['id'] === $record_id);
            });
            foreach($pao2_arr_record as $pao2) {
                $paco2_val = $this->mostPriorPaco2($pao2['dttm'], $paco2_arr_record);
                $fio2_val = $this->mostPriorFio2($pao2['dttm'], $fio2_arr_record);
                if($paco2_val === -99 || $fio2_val === -99) {
                    continue;
                } else {
                    $pao2_val = $pao2['value'];
                    $aao2_val = $this->calculateAao2($pao2_val, $paco2_val, $fio2_val);
                    $aao2_arr_record[] = $aao2_val;
                }
            }
            if (count($aao2_arr_record) > 0) {
                $aao2_max = max($aao2_arr_record);
                $aao2_min = min($aao2_arr_record);
            }

           // $this->emDebug('getAao2() for record ' . $record_id . ':');
           // $this->emDebug($aao2_arr_record);

            $aao2_minmax[] = array(
                'record_id' => strval($record->record_id),
                'tdsr_apache2_aao2_min' => strval($aao2_min),
                'tdsr_apache2_aao2_max' => strval($aao2_max)
            );
        }
        return $aao2_minmax;
    }

    // save results
    public function saveResults($pid, $data) {
        $this->emDebug("saveData() called.");
        $params = array(
            'project_id' => $pid,
            'dataFormat' => 'json',
            'type' => 'flat',
            'data' => json_encode($data),
            'overwriteBehavior' => 'overwrite'
        );
        $response = REDCap::saveData($params);
        $this->emDebug($response);
    }
}
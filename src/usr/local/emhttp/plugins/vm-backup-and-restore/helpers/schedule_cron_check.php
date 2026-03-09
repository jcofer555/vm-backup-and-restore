<?php
declare(strict_types=1);
header('Content-Type: application/json');

const SCHEDULES_CFG = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

$crons_arr = [];

if (file_exists(SCHEDULES_CFG)) {
    $schedules_arr = parse_ini_file(SCHEDULES_CFG, true, INI_SCANNER_RAW);
    if (is_array($schedules_arr)) {
        foreach ($schedules_arr as $id_str => $s_arr) {
            $cron_str     = trim((string)($s_arr['CRON']    ?? ''));
            $enabled_bool = strtolower((string)($s_arr['ENABLED'] ?? 'yes')) === 'yes';
            if ($cron_str !== '') {
                $crons_arr[] = [
                    'id'      => $id_str,
                    'cron'    => $cron_str,
                    'enabled' => $enabled_bool,
                ];
            }
        }
    }
}

echo json_encode($crons_arr);

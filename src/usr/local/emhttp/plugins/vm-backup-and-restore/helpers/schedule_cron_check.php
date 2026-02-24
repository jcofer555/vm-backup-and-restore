<?php
header('Content-Type: application/json');

$cfgs = [
    '/boot/config/plugins/vm-backup-and-restore/schedules.cfg',
];

$crons = [];

foreach ($cfgs as $cfg) {
    if (!file_exists($cfg)) continue;
    $schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);
    if (!is_array($schedules)) continue;

    foreach ($schedules as $id => $s) {
        $cron = trim($s['CRON'] ?? '');
        $enabled = strtolower((string)($s['ENABLED'] ?? 'yes')) === 'yes';
        if ($cron !== '') {
            $crons[] = [
                'id'      => $id,
                'cron'    => $cron,
                'enabled' => $enabled,
            ];
        }
    }
}

echo json_encode($crons);
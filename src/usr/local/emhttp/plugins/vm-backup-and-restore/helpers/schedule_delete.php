<?php
require_once 'rebuild_cron.php';

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
$id  = $_POST['id'];

$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);

// Remove the schedule
unset($schedules[$id]);

$out = '';
foreach ($schedules as $k => $s) {
    $out .= "[$k]\n";

    foreach ($s as $kk => $vv) {
        // Write values exactly as they were stored
        $out .= $kk . '="' . $vv . '"' . "\n";
    }

    $out .= "\n";
}

file_put_contents($cfg, $out);
rebuild_cron();

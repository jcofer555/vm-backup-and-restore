<?php
require_once 'rebuild_cron.php';

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
$id  = $_POST['id'] ?? '';

if (!$id || !file_exists($cfg)) {
    exit;
}

$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);

if (!isset($schedules[$id])) {
    exit;
}

// Normalize ENABLED:
$current = strtolower((string)($schedules[$id]['ENABLED'] ?? 'yes'));
$schedules[$id]['ENABLED'] = ($current === 'yes') ? 'no' : 'yes';

// Write back — ALWAYS quote values, NEVER escape JSON
$out = '';

foreach ($schedules as $section => $values) {
    $out .= "[$section]\n";
    foreach ($values as $key => $value) {
        $out .= $key . '="' . (string)$value . '"' . "\n";
    }
    $out .= "\n";
}

file_put_contents($cfg, $out);

// Rebuild cron AFTER successful write
rebuild_cron();

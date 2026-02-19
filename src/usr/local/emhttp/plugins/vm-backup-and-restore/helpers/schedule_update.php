<?php
require_once 'rebuild_cron.php';

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

$id       = $_POST['id'] ?? '';
$cron     = trim($_POST['cron'] ?? '');
$settings = $_POST['settings'] ?? [];

// Ensure settings is always an array
if (!is_array($settings)) {
    $settings = [];
}

if (!$id) {
    http_response_code(400);
    exit("Missing schedule ID");
}

// Validate cron
if (!preg_match('/^([\*\/0-9,-]+\s+){4}[\*\/0-9,-]+$/', $cron)) {
    http_response_code(400);
    exit("Invalid cron");
}

// Load current schedules safely
if (!file_exists($cfg)) {
    http_response_code(404);
    exit("Schedules file not found");
}

$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);

if (!isset($schedules[$id])) {
    http_response_code(404);
    exit("Schedule not found");
}

// ---- DUPLICATE CHECK ----
$newFingerprint = [
    'VMS_TO_BACKUP'      => $settings['VMS_TO_BACKUP'] ?? '',
    'BACKUP_DESTINATION' => $settings['BACKUP_DESTINATION'] ?? '',
];
ksort($newFingerprint);
$newHash = hash('sha256', json_encode($newFingerprint));

foreach ($schedules as $existingId => $s) {
    if ($existingId === $id) continue;
    if (empty($s['SETTINGS'])) continue;

    $existingSettings = json_decode(stripslashes($s['SETTINGS']), true);
    if (!is_array($existingSettings)) continue;

    $existingFingerprint = [
        'VMS_TO_BACKUP'      => $existingSettings['VMS_TO_BACKUP'] ?? '',
        'BACKUP_DESTINATION' => $existingSettings['BACKUP_DESTINATION'] ?? '',
    ];
    ksort($existingFingerprint);
    $existingHash = hash('sha256', json_encode($existingFingerprint));

    if ($existingHash === $newHash) {
        http_response_code(409);
        echo json_encode([
            'error' => 'Duplicate schedule detected',
            'conflict_id' => $existingId
        ]);
        exit;
    }
}

// ---- Encode settings safely for INI ----
$settingsJson = json_encode($settings, JSON_UNESCAPED_SLASHES);
$settingsJson = addcslashes($settingsJson, '"'); // escape quotes for INI

// ---- Update the schedule ----
$schedules[$id]['CRON']     = $cron;
$schedules[$id]['SETTINGS'] = $settingsJson;

// Rebuild the INI file
$out = '';
foreach ($schedules as $k => $s) {
    $out .= "[$k]\n";
    foreach ($s as $kk => $vv) {
        $out .= "$kk=\"$vv\"\n";
    }
    $out .= "\n";
}

file_put_contents($cfg, $out);

// Rebuild cron jobs
rebuild_cron();

// Success response
echo json_encode(['success' => true]);

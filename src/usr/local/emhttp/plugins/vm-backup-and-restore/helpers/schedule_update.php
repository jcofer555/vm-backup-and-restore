<?php
require_once 'rebuild_cron.php';

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

$id   = $_POST['id'] ?? '';
$cron = trim($_POST['cron'] ?? '');

if (!$id) {
    http_response_code(400);
    exit("Missing schedule ID");
}

// Validate cron
if (!preg_match('/^([\*\/0-9,-]+\s+){4}[\*\/0-9,-]+$/', $cron)) {
    http_response_code(400);
    exit("Invalid cron");
}

// Load current schedules early so we can reference existing data
if (!file_exists($cfg)) {
    http_response_code(404);
    exit("Schedules file not found");
}

$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);

if (!isset($schedules[$id])) {
    http_response_code(404);
    exit("Schedule not found");
}

// Resolve type from POST, fall back to what's already stored
$type = $_POST['type'] ?? $schedules[$id]['TYPE'] ?? '';

// Build and filter settings
$settings = $_POST['settings'] ?? [];

if (!is_array($settings)) {
    $settings = [];
}

// ---- Allowlist by type - only store what belongs ----
if (($_POST['type'] ?? '') === 'restore') {
    $allowed = [
        'VMS_TO_RESTORE',
        'RESTORE_DESTINATION',
        'LOCATION_OF_BACKUPS',
        'DRY_RUN_RESTORE',
        'NOTIFICATIONS_RESTORE',
        'NOTIFICATION_SERVICE',
    ];
} else {
    $allowed = [
        'VMS_TO_BACKUP',
        'BACKUP_DESTINATION',
        'BACKUPS_TO_KEEP',
        'BACKUP_OWNER',
        'DRY_RUN',
        'NOTIFICATIONS',
        'NOTIFICATION_SERVICE',
    ];
}

$settings = array_intersect_key($settings, array_flip($allowed));

// ---- Always exclude these (UI-only / stored elsewhere) ----
$exclude = ['csrf_token', 'CRON_EXPRESSION'];
$settings = array_diff_key($settings, array_flip($exclude));

// ---- Strip keys that don't belong to this schedule type ----
if ($type === 'backup') {
    $strip = ['VMS_TO_RESTORE', 'RESTORE_DESTINATION', 'DRY_RUN_RESTORE', 'NOTIFICATIONS_RESTORE'];
    $settings = array_diff_key($settings, array_flip($strip));
} elseif ($type === 'restore') {
    $strip = ['VMS_TO_BACKUP', 'BACKUP_DESTINATION', 'BACKUPS_TO_KEEP', 'BACKUP_OWNER', 'DRY_RUN', 'NOTIFICATIONS', 'NOTIFICATION_SERVICE', 'LOCATION_OF_BACKUPS'];
    $settings = array_diff_key($settings, array_flip($strip));
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
            'error'       => 'Duplicate schedule detected',
            'conflict_id' => $existingId
        ]);
        exit;
    }
}

// ---- Encode settings safely for INI ----
$settingsJson = json_encode($settings, JSON_UNESCAPED_SLASHES);
$settingsJson = addcslashes($settingsJson, '"');

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
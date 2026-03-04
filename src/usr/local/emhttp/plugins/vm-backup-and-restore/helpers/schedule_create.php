<?php
require_once 'rebuild_cron.php';

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

$type     = $_POST['type'] ?? '';
$cron     = trim($_POST['cron'] ?? '');
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

// ---- Strip restore-only keys from backup schedules (and vice versa) ----
if ($type === 'backup') {
    $strip = ['VMS_TO_RESTORE', 'RESTORE_DESTINATION', 'DRY_RUN_RESTORE', 'NOTIFICATIONS_RESTORE'];
    $settings = array_diff_key($settings, array_flip($strip));
} elseif ($type === 'restore') {
    $strip = ['VMS_TO_BACKUP', 'BACKUP_DESTINATION', 'BACKUPS_TO_KEEP', 'BACKUP_OWNER', 'DRY_RUN', 'NOTIFICATIONS', 'NOTIFICATION_SERVICE', 'LOCATION_OF_BACKUPS'];
    $settings = array_diff_key($settings, array_flip($strip));
}

// Validate cron
if (!preg_match('/^([\*\/0-9,-]+\s+){4}[\*\/0-9,-]+$/', $cron)) {
    http_response_code(400);
    exit("Invalid cron");
}

// Load existing schedules safely
$schedules = [];
if (file_exists($cfg)) {
    $schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);
}

// ---- Compute new fingerprint (ONLY VMS_TO_BACKUP + BACKUP_DESTINATION) ----
$newFingerprint = [
    'VMS_TO_BACKUP'      => $settings['VMS_TO_BACKUP'] ?? '',
    'BACKUP_DESTINATION' => $settings['BACKUP_DESTINATION'] ?? '',
];
ksort($newFingerprint);
$newHash = hash('sha256', json_encode($newFingerprint));

// ---- Check for duplicates based ONLY on VMS_TO_BACKUP + BACKUP_DESTINATION ----
foreach ($schedules as $existingId => $s) {
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

// Generate unique ID
$id = 'schedule_' . time();

// ---- Encode settings safely for INI ----
$settingsJson = json_encode($settings, JSON_UNESCAPED_SLASHES);
$settingsJson = addcslashes($settingsJson, '"');

// Build INI block
$block  = "\n[$id]\n";
$block .= "TYPE=\"$type\"\n";
$block .= "CRON=\"$cron\"\n";
$block .= "ENABLED=\"yes\"\n";
$block .= "SETTINGS=\"$settingsJson\"\n";

// Append to schedules.cfg
file_put_contents($cfg, $block, FILE_APPEND);

// Rebuild cron file
rebuild_cron();

// Success response
echo json_encode([
    'success' => true,
    'id'      => $id
]);
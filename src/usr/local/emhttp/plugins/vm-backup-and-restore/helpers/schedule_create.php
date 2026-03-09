<?php
declare(strict_types=1);
require_once 'rebuild_cron.php';

header('Content-Type: application/json');

// --- Constants ---
const SCHEDULES_CFG = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

const ALLOWED_BACKUP_KEYS  = ['VMS_TO_BACKUP', 'BACKUP_DESTINATION', 'BACKUPS_TO_KEEP', 'BACKUP_OWNER', 'DRY_RUN', 'NOTIFICATIONS', 'NOTIFICATION_SERVICE'];
const ALLOWED_RESTORE_KEYS = ['VMS_TO_RESTORE', 'RESTORE_DESTINATION', 'LOCATION_OF_BACKUPS', 'DRY_RUN_RESTORE', 'NOTIFICATIONS_RESTORE', 'NOTIFICATION_SERVICE'];
const EXCLUDED_KEYS        = ['csrf_token', 'CRON_EXPRESSION'];

// --- Input ---
$type_str     = (string)($_POST['type']     ?? '');
$cron_str     = trim((string)($_POST['cron'] ?? ''));
$settings_raw = $_POST['settings'] ?? [];
$settings_arr = is_array($settings_raw) ? $settings_raw : [];

// --- Filter by type allowlist ---
$allowed_arr = ($type_str === 'restore') ? ALLOWED_RESTORE_KEYS : ALLOWED_BACKUP_KEYS;
$settings_arr = array_intersect_key($settings_arr, array_flip($allowed_arr));
$settings_arr = array_diff_key($settings_arr, array_flip(EXCLUDED_KEYS));

// --- Validate cron expression ---
if (!preg_match('/^([\*\/0-9,-]+\s+){4}[\*\/0-9,-]+$/', $cron_str)) {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Invalid cron expression']);
    exit;
}

// --- Load existing schedules ---
$schedules_arr = [];
if (file_exists(SCHEDULES_CFG)) {
    $schedules_arr = parse_ini_file(SCHEDULES_CFG, true, INI_SCANNER_RAW);
    if (!is_array($schedules_arr)) {
        $schedules_arr = [];
    }
}

// --- Duplicate fingerprint check ---
$new_fingerprint_arr = [
    'VMS_TO_BACKUP'      => $settings_arr['VMS_TO_BACKUP']      ?? '',
    'BACKUP_DESTINATION' => $settings_arr['BACKUP_DESTINATION'] ?? '',
];
ksort($new_fingerprint_arr);
$new_hash_str = hash('sha256', json_encode($new_fingerprint_arr));

foreach ($schedules_arr as $existing_id_str => $s_arr) {
    if (empty($s_arr['SETTINGS'])) {
        continue;
    }
    $existing_settings_arr = json_decode(stripslashes((string)$s_arr['SETTINGS']), true);
    if (!is_array($existing_settings_arr)) {
        continue;
    }
    $existing_fp_arr = [
        'VMS_TO_BACKUP'      => $existing_settings_arr['VMS_TO_BACKUP']      ?? '',
        'BACKUP_DESTINATION' => $existing_settings_arr['BACKUP_DESTINATION'] ?? '',
    ];
    ksort($existing_fp_arr);
    if (hash('sha256', json_encode($existing_fp_arr)) === $new_hash_str) {
        http_response_code(409);
        echo json_encode(['status' => 'error', 'message' => 'Duplicate schedule detected', 'conflict_id' => $existing_id_str]);
        exit;
    }
}

// --- Generate unique ID and encode settings ---
$id_str           = 'schedule_' . time();
$settings_json_str = addcslashes(json_encode($settings_arr, JSON_UNESCAPED_SLASHES), '"');

$block_str  = "\n[$id_str]\n";
$block_str .= "TYPE=\"$type_str\"\n";
$block_str .= "CRON=\"$cron_str\"\n";
$block_str .= "ENABLED=\"yes\"\n";
$block_str .= "SETTINGS=\"$settings_json_str\"\n";

file_put_contents(SCHEDULES_CFG, $block_str, FILE_APPEND);
rebuild_cron();

echo json_encode(['success' => true, 'id' => $id_str]);

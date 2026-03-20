<?php
declare(strict_types=1);
require_once 'rebuild_cron.php';

header('Content-Type: application/json');

// --- Constants ---
const SCHEDULES_CFG = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

const ALLOWED_BACKUP_KEYS  = ['VMS_TO_BACKUP', 'BACKUP_DESTINATION', 'BACKUPS_TO_KEEP', 'BACKUP_OWNER', 'DRY_RUN', 'NOTIFICATIONS', 'NOTIFICATION_SERVICE'];
const ALLOWED_RESTORE_KEYS = ['VMS_TO_RESTORE', 'RESTORE_DESTINATION', 'LOCATION_OF_BACKUPS', 'DRY_RUN_RESTORE', 'NOTIFICATIONS_RESTORE', 'NOTIFICATION_SERVICE'];
const EXCLUDED_KEYS        = ['csrf_token', 'CRON_EXPRESSION'];

// --- CSRF validation ---
$csrf_cookie_str = $_COOKIE['csrf_token'] ?? '';
$csrf_post_str   = $_POST['csrf_token']   ?? '';
if ($csrf_cookie_str !== '' && !hash_equals($csrf_cookie_str, $csrf_post_str)) {
    http_response_code(403);
    echo json_encode(['status' => 'error', 'message' => 'Invalid CSRF token']);
    exit;
}

$id_str   = (string)($_POST['id']   ?? '');
$cron_str = trim((string)($_POST['cron'] ?? ''));

if ($id_str === '') {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Missing schedule ID']);
    exit;
}

if (!preg_match('/^([\*\/0-9,-]+\s+){4}[\*\/0-9,-]+$/', $cron_str)) {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Invalid cron expression']);
    exit;
}

if (!file_exists(SCHEDULES_CFG)) {
    http_response_code(404);
    echo json_encode(['status' => 'error', 'message' => 'Schedules file not found']);
    exit;
}

$schedules_arr = parse_ini_file(SCHEDULES_CFG, true, INI_SCANNER_RAW);
if (!is_array($schedules_arr) || !isset($schedules_arr[$id_str])) {
    http_response_code(404);
    echo json_encode(['status' => 'error', 'message' => 'Schedule not found']);
    exit;
}

$type_str    = (string)($_POST['type'] ?? $schedules_arr[$id_str]['TYPE'] ?? '');
$settings_raw = $_POST['settings'] ?? [];
$settings_arr = is_array($settings_raw) ? $settings_raw : [];

$allowed_arr  = ($type_str === 'restore') ? ALLOWED_RESTORE_KEYS : ALLOWED_BACKUP_KEYS;
$settings_arr = array_intersect_key($settings_arr, array_flip($allowed_arr));
$settings_arr = array_diff_key($settings_arr, array_flip(EXCLUDED_KEYS));

// --- Duplicate fingerprint check (skip self) ---
$new_fp_arr = [
    'VMS_TO_BACKUP'      => $settings_arr['VMS_TO_BACKUP']      ?? '',
    'BACKUP_DESTINATION' => $settings_arr['BACKUP_DESTINATION'] ?? '',
];
ksort($new_fp_arr);
$new_hash_str = hash('sha256', json_encode($new_fp_arr));

foreach ($schedules_arr as $existing_id_str => $s_arr) {
    if ($existing_id_str === $id_str || empty($s_arr['SETTINGS'])) {
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

$settings_json_str = addcslashes(json_encode($settings_arr, JSON_UNESCAPED_SLASHES), '"');

$schedules_arr[$id_str]['CRON']     = $cron_str;
$schedules_arr[$id_str]['SETTINGS'] = $settings_json_str;

$out_str = '';
foreach ($schedules_arr as $k_str => $s_arr) {
    $out_str .= "[$k_str]\n";
    foreach ($s_arr as $kk_str => $vv_str) {
        $out_str .= "$kk_str=\"$vv_str\"\n";
    }
    $out_str .= "\n";
}

file_put_contents(SCHEDULES_CFG, $out_str);
rebuild_cron();

echo json_encode(['status' => 'ok']);
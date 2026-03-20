<?php
declare(strict_types=1);
require_once 'rebuild_cron.php';

header('Content-Type: application/json');

const SCHEDULES_CFG = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

// --- CSRF validation ---
$csrf_cookie_str = $_COOKIE['csrf_token'] ?? '';
$csrf_post_str   = $_POST['csrf_token']   ?? '';
if ($csrf_cookie_str !== '' && !hash_equals($csrf_cookie_str, $csrf_post_str)) {
    http_response_code(403);
    echo json_encode(['status' => 'error', 'message' => 'Invalid CSRF token']);
    exit;
}

$id_str = (string)($_POST['id'] ?? '');

if ($id_str === '' || !file_exists(SCHEDULES_CFG)) {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Missing ID or schedules file not found']);
    exit;
}

$schedules_arr = parse_ini_file(SCHEDULES_CFG, true, INI_SCANNER_RAW);
if (!is_array($schedules_arr) || !isset($schedules_arr[$id_str])) {
    http_response_code(404);
    echo json_encode(['status' => 'error', 'message' => 'Schedule not found']);
    exit;
}

$current_str = strtolower((string)($schedules_arr[$id_str]['ENABLED'] ?? 'yes'));
$schedules_arr[$id_str]['ENABLED'] = ($current_str === 'yes') ? 'no' : 'yes';

$out_str = '';
foreach ($schedules_arr as $section_str => $values_arr) {
    $out_str .= "[$section_str]\n";
    foreach ($values_arr as $key_str => $val_str) {
        $out_str .= $key_str . '="' . (string)$val_str . '"' . "\n";
    }
    $out_str .= "\n";
}

file_put_contents(SCHEDULES_CFG, $out_str);
rebuild_cron();

echo json_encode(['status' => 'ok']);
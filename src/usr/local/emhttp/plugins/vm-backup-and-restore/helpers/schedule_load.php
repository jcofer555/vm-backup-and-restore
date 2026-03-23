<?php

declare(strict_types=1);
header('Content-Type: application/json');

const SCHEDULES_CFG = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';

$id_str = (string)($_GET['id'] ?? '');

if ($id_str === '') {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Missing schedule ID']);
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

$entry_arr = $schedules_arr[$id_str];

$raw_settings_str  = (string)($entry_arr['SETTINGS'] ?? '{}');
$settings_arr      = json_decode(stripslashes($raw_settings_str), true);
if (!is_array($settings_arr)) {
    $settings_arr = [];
}

$entry_arr['SETTINGS'] = $settings_arr;

echo json_encode($entry_arr);

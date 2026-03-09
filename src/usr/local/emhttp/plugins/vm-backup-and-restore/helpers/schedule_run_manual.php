<?php
declare(strict_types=1);
header('Content-Type: application/json');

// --- Constants ---
const SCHEDULES_CFG   = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
const LOCK_DIR        = '/tmp/vm-backup-and-restore';
const LOCK_FILE       = LOCK_DIR . '/lock.txt';
const SCHEDULE_SCRIPT = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/scheduled_backup.sh';

// --- Utility ---
function json_error(string $message): void
{
    echo json_encode(['status' => 'error', 'message' => $message]);
    exit;
}

$id_str = (string)($_POST['id'] ?? '');

if ($id_str === '') {
    http_response_code(400);
    json_error('Missing schedule ID');
}

if (!file_exists(SCHEDULES_CFG)) {
    http_response_code(404);
    json_error('Schedules file not found');
}

$schedules_arr = parse_ini_file(SCHEDULES_CFG, true, INI_SCANNER_RAW);
if (!is_array($schedules_arr) || !isset($schedules_arr[$id_str])) {
    http_response_code(404);
    json_error('Schedule not found');
}

$settings_arr = json_decode(stripslashes((string)($schedules_arr[$id_str]['SETTINGS'] ?? '{}')), true);
if (!is_array($settings_arr)) {
    http_response_code(500);
    json_error('Invalid schedule settings');
}

// --- Ensure lock directory ---
if (!is_dir(LOCK_DIR)) {
    mkdir(LOCK_DIR, 0777, true);
}

// --- Validate script ---
if (!is_file(SCHEDULE_SCRIPT) || !is_executable(SCHEDULE_SCRIPT)) {
    json_error('Scheduled backup script missing or not executable');
}

// --- Check for live process ---
if (file_exists(LOCK_FILE)) {
    $contents_str = (string)file_get_contents(LOCK_FILE);
    preg_match('/PID=(\d+)/', $contents_str, $pid_matches);
    $existing_pid_int = isset($pid_matches[1]) ? (int)$pid_matches[1] : 0;
    if ($existing_pid_int > 0 && file_exists("/proc/$existing_pid_int")) {
        json_error('Backup already running');
    }
    @unlink(LOCK_FILE);
}

// --- Write placeholder lock before launch ---
$placeholder_str = "PID=0\nMODE=schedule-manual\nSCHEDULE_ID=$id_str\nSTART=" . time() . "\n";
if (file_put_contents(LOCK_FILE, $placeholder_str, LOCK_EX) === false) {
    json_error('Unable to write lock file');
}

// --- Build env string and launch ---
$env_str = '';
foreach ($settings_arr as $key_str => $val_str) {
    $env_str .= escapeshellarg($key_str) . '=' . escapeshellarg((string)$val_str) . ' ';
}
$env_str .= 'SCHEDULE_ID=' . escapeshellarg($id_str) . ' ';

$cmd_str = 'nohup /usr/bin/env ' . $env_str . '/bin/bash ' . escapeshellarg(SCHEDULE_SCRIPT) . ' >/dev/null 2>&1 & echo $!';
$pid_str = trim((string)shell_exec($cmd_str));

if ($pid_str === '' || !is_numeric($pid_str)) {
    @unlink(LOCK_FILE);
    json_error('Failed to start scheduled backup');
}

$pid_int = (int)$pid_str;
file_put_contents(LOCK_FILE, "PID=$pid_int\nMODE=schedule-manual\nSCHEDULE_ID=$id_str\nSTART=" . time() . "\n", LOCK_EX);

echo json_encode([
    'status'  => 'ok',
    'started' => true,
    'id'      => $id_str,
    'pid'     => $pid_int,
]);

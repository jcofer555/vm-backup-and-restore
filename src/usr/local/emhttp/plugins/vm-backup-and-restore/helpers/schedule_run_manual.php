<?php
header('Content-Type: application/json');

$id = $_POST['id'] ?? '';
if (!$id) {
    http_response_code(400);
    echo json_encode(['status' => 'error', 'message' => 'Missing schedule ID']);
    exit;
}

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
if (!file_exists($cfg)) {
    http_response_code(404);
    echo json_encode(['status' => 'error', 'message' => 'Schedules file not found']);
    exit;
}

$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);
if (!isset($schedules[$id])) {
    http_response_code(404);
    echo json_encode(['status' => 'error', 'message' => 'Schedule not found']);
    exit;
}

$s = $schedules[$id];
$settings = json_decode($s['SETTINGS'], true);
if (!is_array($settings)) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Invalid schedule settings']);
    exit;
}

// Build environment variable string
$env = '';
foreach ($settings as $k => $v) {
    $env .= $k . '="' . addslashes($v) . '" ';
}
$env .= 'SCHEDULE_ID="' . addslashes($id) . '" ';

// Lock file
$lockDir = '/tmp/vm-backup-and-restore';
$lock = "$lockDir/lock.txt";

if (!is_dir($lockDir)) {
    mkdir($lockDir, 0777, true);
}

// Open lock file (create if missing)
$fp = fopen($lock, 'c');
if (!$fp) {
    echo json_encode(['status' => 'error', 'message' => 'Unable to open lock file']);
    exit;
}

// Try to acquire exclusive lock (non-blocking)
if (!flock($fp, LOCK_EX | LOCK_NB)) {
    echo json_encode(['status' => 'error', 'message' => 'Backup already running']);
    exit;
}

$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/scheduled_backup.sh';

if (!is_file($script) || !is_executable($script)) {
    echo json_encode(['status' => 'error', 'message' => 'Scheduled backup script missing or not executable']);
    exit;
}

// Launch script with environment variables
$cmd = "nohup /usr/bin/env $env /bin/bash $script >/dev/null 2>&1 & echo $!";
$pid = trim(shell_exec($cmd));

if (!$pid || !is_numeric($pid)) {
    echo json_encode(['status' => 'error', 'message' => 'Failed to start scheduled backup']);
    exit;
}

// Write metadata atomically
$meta = [
    "PID=$pid",
    "MODE=schedule-manual",
    "SCHEDULE_ID=$id",
    "START=" . time()
];

ftruncate($fp, 0);
fwrite($fp, implode("\n", $meta) . "\n");
fflush($fp);

// Keep lock held by keeping $fp open

echo json_encode([
    'status' => 'ok',
    'started' => true,
    'id' => $id,
    'pid' => $pid
]);

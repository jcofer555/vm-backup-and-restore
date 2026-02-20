<?php
header('Content-Type: application/json');

$id = $argv[1] ?? ($_GET['id'] ?? ($_POST['id'] ?? ''));

if (!$id) {
    echo json_encode(['status' => 'error', 'message' => 'Missing schedule id']);
    exit;
}

$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);

if (!isset($schedules[$id])) {
    echo json_encode(['status' => 'error', 'message' => 'Schedule not found']);
    exit;
}

$lockDir = '/tmp/vm-backup-and-restore';
$lock = "$lockDir/lock.txt";
$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/scheduled_backup.sh';

if (!is_dir($lockDir)) {
    mkdir($lockDir, 0777, true);
}

$fp = fopen($lock, 'c');
if (!$fp) {
    echo json_encode(['status' => 'error', 'message' => 'Unable to open lock file']);
    exit;
}

if (!flock($fp, LOCK_EX | LOCK_NB)) {
    echo json_encode(['status' => 'error', 'message' => 'Backup already running']);
    exit;
}

// Decode settings
$rawSettings = stripslashes($schedules[$id]['SETTINGS'] ?? '');
$settings = json_decode($rawSettings, true);
if (!is_array($settings)) $settings = [];

foreach ($settings as $k => $v) {
    putenv("$k=$v");
}
putenv("SCHEDULE_ID=$id");

if (!is_file($script) || !is_executable($script)) {
    echo json_encode(['status' => 'error', 'message' => 'Scheduled backup script missing or not executable']);
    exit;
}

$cmd = "nohup /bin/bash $script >/dev/null 2>&1 & echo $!";
$pid = trim(shell_exec($cmd));

if (!$pid || !is_numeric($pid)) {
    echo json_encode(['status' => 'error', 'message' => 'Failed to start scheduled backup']);
    exit;
}

$meta = [
    "PID=$pid",
    "MODE=schedule",
    "SCHEDULE_ID=$id",
    "START=" . time()
];

ftruncate($fp, 0);
fwrite($fp, implode("\n", $meta) . "\n");
fflush($fp);

echo json_encode([
    'status' => 'ok',
    'started' => true,
    'id' => $id,
    'pid' => $pid
]);

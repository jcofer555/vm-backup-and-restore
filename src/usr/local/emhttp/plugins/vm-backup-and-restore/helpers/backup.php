<?php
header('Content-Type: application/json');

$lockDir = '/tmp/vm-backup-and-restore';
$lock = "$lockDir/lock.txt";
$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/backup.sh';

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

if (!is_file($script) || !is_executable($script)) {
    echo json_encode(['status' => 'error', 'message' => 'Backup script missing or not executable']);
    exit;
}

// Start backup.sh and capture PID
$cmd = "nohup /bin/bash $script >/dev/null 2>&1 & echo $!";
$pid = trim(shell_exec($cmd));

if (!$pid || !is_numeric($pid)) {
    echo json_encode(['status' => 'error', 'message' => 'Failed to start backup']);
    exit;
}

// Write metadata atomically
$meta = [
    "PID=$pid",
    "MODE=manual",
    "START=" . time()
];

ftruncate($fp, 0);
fwrite($fp, implode("\n", $meta) . "\n");
fflush($fp);

echo json_encode([
    'status' => 'ok',
    'pid' => $pid
]);

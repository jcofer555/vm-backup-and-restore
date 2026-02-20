<?php
header('Content-Type: application/json');

$lockDir = '/tmp/vm-backup-and-restore';
$lock = "$lockDir/lock.txt";
$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/restore.sh';

if (!is_dir($lockDir)) {
    mkdir($lockDir, 0777, true);
}

$fp = fopen($lock, 'c');
if (!$fp) {
    echo json_encode(['status' => 'error', 'message' => 'Unable to open lock file']);
    exit;
}

if (!flock($fp, LOCK_EX | LOCK_NB)) {
    echo json_encode(['status' => 'error', 'message' => 'Backup or restore already running']);
    exit;
}

if (!is_file($script) || !is_executable($script)) {
    echo json_encode(['status' => 'error', 'message' => 'Restore script missing or not executable']);
    exit;
}

$cmd = "nohup /bin/bash $script >/dev/null 2>&1 & echo $!";
$pid = trim(shell_exec($cmd));

if (!$pid || !is_numeric($pid)) {
    echo json_encode(['status' => 'error', 'message' => 'Failed to start restore']);
    exit;
}

$meta = [
    "PID=$pid",
    "MODE=restore",
    "START=" . time()
];

ftruncate($fp, 0);
fwrite($fp, implode("\n", $meta) . "\n");
fflush($fp);

echo json_encode([
    'status' => 'ok',
    'pid' => $pid
]);

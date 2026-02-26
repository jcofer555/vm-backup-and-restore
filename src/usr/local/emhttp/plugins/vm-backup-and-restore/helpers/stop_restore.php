<?php
header('Content-Type: application/json');

$lock = '/tmp/vm-backup-and-restore/lock.txt';

if (!file_exists($lock)) {
    http_response_code(400);
    echo json_encode(['error' => 'No restore running']);
    exit;
}

// Kill rsync if it's running
$rsyncPid = trim(@file_get_contents('/tmp/vm-backup-and-restore/restore_rsync.pid'));
if ($rsyncPid && is_numeric($rsyncPid)) {
    shell_exec("kill -15 " . $rsyncPid . " 2>&1");
}

// Touch stop flag so restore.sh knows to exit
touch('/tmp/vm-backup-and-restore/restore_stop_requested.txt');

echo json_encode(['ok' => true]);
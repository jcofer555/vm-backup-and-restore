<?php
declare(strict_types=1);
header('Content-Type: application/json');

const LOCK_FILE      = '/tmp/vm-backup-and-restore/lock.txt';
const RSYNC_PID_FILE = '/tmp/vm-backup-and-restore/restore_rsync.pid';
const STOP_FLAG      = '/tmp/vm-backup-and-restore/restore_stop_requested.txt';

if (!file_exists(LOCK_FILE)) {
    http_response_code(400);
    echo json_encode(['error' => 'No restore running']);
    exit;
}

// Kill rsync if running
if (file_exists(RSYNC_PID_FILE)) {
    $rsync_pid_str = trim((string)file_get_contents(RSYNC_PID_FILE));
    if ($rsync_pid_str !== '' && is_numeric($rsync_pid_str)) {
        shell_exec('kill -15 ' . escapeshellarg($rsync_pid_str) . ' 2>/dev/null');
    }
}

touch(STOP_FLAG);

echo json_encode(['ok' => true]);

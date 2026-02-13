<?php
header('Content-Type: application/json');

$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/backup.sh';

if (!is_file($script) || !is_executable($script)) {
    echo json_encode([
        'status' => 'error',
        'message' => 'Backup script missing or not executable'
    ]);
    exit;
}

// Run in background
$cmd = "nohup $script >/dev/null 2>&1 & echo $!";
$pid = trim(shell_exec($cmd));

echo json_encode([
    'status' => 'ok',
    'pid' => $pid
]);

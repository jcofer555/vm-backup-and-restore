<?php
header('Content-Type: application/json');

$script = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/restore.sh';

if (!is_file($script) || !is_executable($script)) {
    echo json_encode([
        'status' => 'error',
        'message' => 'Restore script missing or not executable'
    ]);
    exit;
}

// Run in background so UI doesn't hang
$cmd = "nohup $script > /tmp/vm-restore.log 2>&1 & echo $!";
$pid = trim(shell_exec($cmd));

echo json_encode([
    'status' => 'ok',
    'pid' => $pid
]);

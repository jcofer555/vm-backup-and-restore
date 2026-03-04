<?php
header('Content-Type: application/json');

$lockDir = '/tmp/vm-backup-and-restore';
$lock    = "$lockDir/lock.txt";
$script  = '/usr/local/emhttp/plugins/vm-backup-and-restore/helpers/backup.sh';

if (!is_dir($lockDir)) {
    mkdir($lockDir, 0777, true);
}

// Atomic check-and-write using exclusive open (x mode = fail if exists)
// First verify no live process holds it
if (file_exists($lock)) {
    $contents = file_get_contents($lock);
    preg_match('/PID=(\d+)/', $contents, $pm);
    $pid = $pm[1] ?? null;
    if ($pid && file_exists("/proc/$pid")) {
        echo json_encode(['status' => 'error', 'message' => 'Backup already running']);
        exit;
    }
    // Stale — remove it
    @unlink($lock);
}

if (!is_file($script) || !is_executable($script)) {
    echo json_encode(['status' => 'error', 'message' => 'Backup script missing or not executable']);
    exit;
}

// Write placeholder lock BEFORE launching so the window is closed
$placeholder = "PID=0\nMODE=manual\nSTART=" . time() . "\n";
if (file_put_contents($lock, $placeholder, LOCK_EX) === false) {
    echo json_encode(['status' => 'error', 'message' => 'Unable to write lock file']);
    exit;
}

// Launch — the script will overwrite PID=0 with its real PID immediately
$cmd = "nohup /bin/bash $script >/dev/null 2>&1 & echo $!";
$pid = trim(shell_exec($cmd));

if (!$pid || !is_numeric($pid)) {
    @unlink($lock);
    echo json_encode(['status' => 'error', 'message' => 'Failed to start backup']);
    exit;
}

// Update with real PID
file_put_contents($lock, "PID=$pid\nMODE=manual\nSTART=" . time() . "\n", LOCK_EX);

echo json_encode(['status' => 'ok', 'pid' => $pid]);
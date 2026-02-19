<?php
$logPath = '/tmp/vm-backup-and-restore/vm-backup-and-restore.log';
header('Content-Type: text/plain');

if (!file_exists($logPath)) {
    echo "Backup & restore log not found";
    exit;
}

$lines = file($logPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);

// Get last 500 entries
$tail = array_slice($lines, -500);

// Show newest at the top
$reversed = array_reverse($tail);

// Display
echo implode("\n", $reversed);

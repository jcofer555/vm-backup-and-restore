<?php
header('Content-Type: application/json');

$lock = '/tmp/vm-backup-and-restore/lock.txt';

if (!file_exists($lock)) {
    echo json_encode(['locked' => false, 'mode' => null]);
    exit;
}

$contents = file_get_contents($lock);

if (empty(trim($contents))) {
    echo json_encode(['locked' => false, 'mode' => null]);
    exit;
}

preg_match('/PID=(\d+)/', $contents, $pm);
preg_match('/MODE=(\S+)/', $contents, $mm);

$pid  = $pm[1] ?? null;
$mode = $mm[1] ?? null;

// Verify the process is actually still running
if ($pid && !file_exists("/proc/$pid")) {
    // Stale lock — clean it up
    @unlink($lock);
    echo json_encode(['locked' => false, 'mode' => null]);
    exit;
}

echo json_encode([
    'locked' => true,
    'mode'   => $mode
]);
<?php
declare(strict_types=1);
header('Content-Type: application/json');

const LOCK_FILE = '/tmp/vm-backup-and-restore/lock.txt';

if (!file_exists(LOCK_FILE)) {
    echo json_encode(['locked' => false, 'mode' => null]);
    exit;
}

$contents_str = (string)file_get_contents(LOCK_FILE);

if (trim($contents_str) === '') {
    echo json_encode(['locked' => false, 'mode' => null]);
    exit;
}

preg_match('/PID=(\d+)/', $contents_str, $pid_matches);
preg_match('/MODE=(\S+)/', $contents_str, $mode_matches);

$pid_int   = isset($pid_matches[1])  ? (int)$pid_matches[1]    : 0;
$mode_str  = $mode_matches[1]  ?? null;

// Stale lock check
if ($pid_int > 0 && !file_exists("/proc/$pid_int")) {
    @unlink(LOCK_FILE);
    echo json_encode(['locked' => false, 'mode' => null]);
    exit;
}

echo json_encode([
    'locked' => true,
    'mode'   => $mode_str,
]);

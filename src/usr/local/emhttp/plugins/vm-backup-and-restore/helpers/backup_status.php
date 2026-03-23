<?php

declare(strict_types=1);
header('Content-Type: application/json');

const LOCK_FILE = '/tmp/vm-backup-and-restore/lock.txt';

if (!file_exists(LOCK_FILE)) {
    echo json_encode(['running' => false]);
    exit;
}

$contents_str = (string)file_get_contents(LOCK_FILE);

if (trim($contents_str) === '') {
    echo json_encode(['running' => false]);
    exit;
}

preg_match('/PID=(\d+)/', $contents_str, $pid_matches);
$pid_int = isset($pid_matches[1]) ? (int)$pid_matches[1] : 0;

// Stale lock — process no longer exists
if ($pid_int > 0 && !file_exists("/proc/$pid_int")) {
    @unlink(LOCK_FILE);
    echo json_encode(['running' => false]);
    exit;
}

// PID=0 means placeholder was written but process not yet updated — treat as running
echo json_encode(['running' => true]);

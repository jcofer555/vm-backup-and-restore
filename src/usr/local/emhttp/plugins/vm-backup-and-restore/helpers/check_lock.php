<?php
$lock = '/tmp/vm-backup-and-restore/lock.txt';

header('Content-Type: application/json');

$locked = file_exists($lock);
$mode = null;

if ($locked) {
    $contents = file_get_contents($lock);
    preg_match('/MODE=(\S+)/', $contents, $m);
    $mode = $m[1] ?? null;
}

echo json_encode([
    'locked' => $locked,
    'mode' => $mode
]);
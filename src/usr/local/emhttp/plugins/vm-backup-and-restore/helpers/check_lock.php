<?php
$lock = '/tmp/vm-backup-and-restore/lock.txt';

header('Content-Type: application/json');
echo json_encode([
    'locked' => file_exists($lock)
]);

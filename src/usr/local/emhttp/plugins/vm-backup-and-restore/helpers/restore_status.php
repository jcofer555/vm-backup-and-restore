<?php
declare(strict_types=1);
header('Content-Type: application/json');

const LOCK_FILE = '/tmp/vm-backup-and-restore/lock.txt';

$running_bool = file_exists(LOCK_FILE);

echo json_encode([
    'running' => $running_bool,
]);

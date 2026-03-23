<?php

declare(strict_types=1);
header('Content-Type: application/json');

const STATUS_FILE = '/tmp/vm-backup-and-restore/backup_status.txt';
const NO_BACKUP_RUNNING = 'No Backup Running';

$status_str = NO_BACKUP_RUNNING;

if (file_exists(STATUS_FILE)) {
    $raw_str = trim((string)file_get_contents(STATUS_FILE));
    if ($raw_str !== '') {
        $status_str = $raw_str;
    }
}

$running_bool = ($status_str !== NO_BACKUP_RUNNING);

echo json_encode([
    'status'  => $status_str,
    'running' => $running_bool,
]);

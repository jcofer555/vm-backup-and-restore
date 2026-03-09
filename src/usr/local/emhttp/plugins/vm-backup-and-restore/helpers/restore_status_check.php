<?php
declare(strict_types=1);
header('Content-Type: application/json');

const STATUS_FILE       = '/tmp/vm-backup-and-restore/restore_status.txt';
const NO_RESTORE_RUNNING = 'No Restore Running';

$status_str = NO_RESTORE_RUNNING;

if (file_exists(STATUS_FILE)) {
    $raw_str = trim((string)file_get_contents(STATUS_FILE));
    if ($raw_str !== '') {
        $status_str = $raw_str;
    }
}

echo json_encode([
    'status' => $status_str,
]);

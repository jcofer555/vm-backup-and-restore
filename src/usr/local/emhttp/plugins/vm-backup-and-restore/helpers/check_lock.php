<?php
header('Content-Type: application/json');
$lockFile = '/tmp/vm-backup-and-restore/lock.txt';
echo json_encode(['locked' => file_exists($lockFile)]);

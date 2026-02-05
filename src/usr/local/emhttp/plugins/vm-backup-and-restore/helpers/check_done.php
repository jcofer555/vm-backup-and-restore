<?php
header('Content-Type: application/json');
$doneFile = '/tmp/vm-backup-and-restore/temp_logs/done.txt';
echo json_encode(['done' => file_exists($doneFile)]);

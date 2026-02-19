<?php
$cfg = '/boot/config/plugins/vm-backup-and-restore/schedules.cfg';
$id = $_GET['id'] ?? null;

if (!$id) {
    http_response_code(400);
    exit("Missing schedule ID");
}

if (!file_exists($cfg)) {
    http_response_code(404);
    exit("Schedules file not found");
}

// Read all schedules safely
$schedules = parse_ini_file($cfg, true, INI_SCANNER_RAW);

if (!isset($schedules[$id])) {
    http_response_code(404);
    exit("Schedule not found");
}

$entry = $schedules[$id];

// ---- Decode SETTINGS JSON safely ----
$settingsRaw = $entry['SETTINGS'] ?? '{}';

// Remove any extra escaping added when writing to INI
$settings = json_decode(stripslashes($settingsRaw), true);

// Ensure it’s always an array
if (!is_array($settings)) {
    $settings = [];
}

// Replace SETTINGS in entry with parsed array
$entry['SETTINGS'] = $settings;

// Return JSON to JS
header('Content-Type: application/json');
echo json_encode($entry);

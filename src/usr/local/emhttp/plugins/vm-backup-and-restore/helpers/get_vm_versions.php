<?php
declare(strict_types=1);
header('Content-Type: application/json');

$vm_str           = $_GET['vm']           ?? '';
$restore_path_str = rtrim($_GET['restore_path'] ?? '', '/');
$base_path_str    = $restore_path_str . '/' . $vm_str;

if (!is_dir($base_path_str)) {
    echo json_encode([]);
    exit;
}

$files_arr    = scandir($base_path_str);
$versions_arr = [];

foreach ($files_arr as $file_str) {
    if (preg_match('/^(\d{8})_(\d{6})/', $file_str, $matches_arr)) {
        $raw_str = $matches_arr[1] . '-' . $matches_arr[2];
        $versions_arr[$raw_str][] = $file_str;
    }
}

$out_arr = [];

foreach ($versions_arr as $raw_str => $files_for_version_arr) {

    $has_disk_bool  = false;
    $has_xml_bool   = false;
    $has_nvram_bool = false;

    foreach ($files_for_version_arr as $file_str) {
        $ext_str = strtolower(pathinfo($file_str, PATHINFO_EXTENSION));
        if ($ext_str === 'img' || $ext_str === 'qcow2') {
            $has_disk_bool = true;
        }
        if ($ext_str === 'xml') {
            $has_xml_bool = true;
        }
        if ($ext_str === 'fd') {
            $has_nvram_bool = true;
        }
    }

    $missing_arr = [];
    if (!$has_disk_bool)  $missing_arr[] = 'vdisk';
    if (!$has_xml_bool)   $missing_arr[] = 'xml';
    if (!$has_nvram_bool) $missing_arr[] = 'nvram';

    $dt_obj      = DateTime::createFromFormat('Ymd-His', $raw_str);
    $display_str = $dt_obj ? $dt_obj->format('Y-m-d H:i:s') : $raw_str;

    $out_arr[] = [
        'raw'      => $raw_str,
        'display'  => $display_str,
        'malformed' => count($missing_arr) > 0,
        'missing'  => $missing_arr,
    ];
}

usort($out_arr, static fn(array $a, array $b): int => strcmp($b['raw'], $a['raw']));

echo json_encode($out_arr);

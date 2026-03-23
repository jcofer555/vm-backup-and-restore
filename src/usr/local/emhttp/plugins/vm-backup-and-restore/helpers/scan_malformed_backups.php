<?php

declare(strict_types=1);
header('Content-Type: application/json');

$restore_path_str = rtrim($_GET['restore_path'] ?? '', '/');

if ($restore_path_str === '' || !is_dir($restore_path_str) || strpos($restore_path_str, '/mnt') !== 0) {
    echo json_encode([]);
    exit;
}

$result_arr = [];

foreach (scandir($restore_path_str) as $vm_folder_str) {
    if (in_array($vm_folder_str, ['.', '..', 'logs'], true)) {
        continue;
    }

    $vm_path_str = $restore_path_str . '/' . $vm_folder_str;
    if (!is_dir($vm_path_str)) {
        continue;
    }

    $groups_arr = [];

    foreach (scandir($vm_path_str) as $file_str) {
        if (preg_match('/^(\d{8})_(\d{6})_.*\.(img|qcow2|xml|fd)$/i', $file_str, $matches_arr)) {
            $timestamp_str = $matches_arr[1] . '-' . $matches_arr[2];
            $ext_str       = strtolower($matches_arr[3]);

            if (!isset($groups_arr[$timestamp_str])) {
                $groups_arr[$timestamp_str] = ['img' => false, 'qcow2' => false, 'xml' => false, 'fd' => false];
            }
            $groups_arr[$timestamp_str][$ext_str] = true;
        }
    }

    foreach ($groups_arr as $ts_str => $found_arr) {
        $has_disk_bool  = $found_arr['img'] || $found_arr['qcow2'];
        $has_xml_bool   = $found_arr['xml'];
        $has_nvram_bool = $found_arr['fd'];

        $missing_arr = [];
        if (!$has_disk_bool)  $missing_arr[] = 'vdisk';
        if (!$has_xml_bool)   $missing_arr[] = 'xml';
        if (!$has_nvram_bool) $missing_arr[] = 'nvram';

        if (!empty($missing_arr)) {
            $dt_obj      = DateTime::createFromFormat('Ymd-His', $ts_str);
            $display_str = $dt_obj ? $dt_obj->format('Y-m-d H:i:s') : $ts_str;

            $result_arr[] = [
                'vm'      => $vm_folder_str,
                'backup'  => $display_str,
                'missing' => $missing_arr,
            ];
        }
    }
}

echo json_encode($result_arr);

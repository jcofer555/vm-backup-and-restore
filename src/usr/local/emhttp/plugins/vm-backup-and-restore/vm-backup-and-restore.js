'use strict';

// ── Custom alert / confirm dialogs ────────────────────────────────────────────
function vmbrAlert(msg, title) {
  const overlay = document.getElementById('vmbr-alert-overlay');
  const msgEl = document.getElementById('vmbr-alert-msg');
  const titEl = document.getElementById('vmbr-alert-title');
  const okBtn = document.getElementById('vmbr-alert-ok');
  if (!overlay) return;
  if (titEl) titEl.textContent = title || 'Notice';
  msgEl.textContent = msg;
  overlay.classList.add('open');
  function handleOk() { overlay.classList.remove('open'); okBtn.removeEventListener('click', handleOk); }
  okBtn.addEventListener('click', handleOk);
}

function vmbrConfirm(msg, onOk, title) {
  const overlay = document.getElementById('vmbr-confirm-overlay');
  const msgEl = document.getElementById('vmbr-confirm-msg');
  const titEl = document.getElementById('vmbr-confirm-title');
  const okBtn = document.getElementById('vmbr-confirm-ok');
  const canBtn = document.getElementById('vmbr-confirm-cancel');
  if (!overlay) { if (onOk) onOk(); return; }
  if (titEl) titEl.textContent = title || 'Confirm';
  msgEl.textContent = msg;
  overlay.classList.add('open');
  function cleanup() { overlay.classList.remove('open'); okBtn.removeEventListener('click', handleOk); canBtn.removeEventListener('click', handleCancel); }
  function handleOk() { cleanup(); if (onOk) onOk(); }
  function handleCancel() { cleanup(); }
  okBtn.addEventListener('click', handleOk);
  canBtn.addEventListener('click', handleCancel);
}

// ── Mode switcher ─────────────────────────────────────────────────────────────
function vmbrSwitchMode(mode_str) {
  const isBackup_bool = (mode_str === 'backup');
  $('#vmbr-backup-panel').toggle(isBackup_bool);
  $('#vmbr-restore-panel').toggle(!isBackup_bool);
  $('#vmbr-active-card-title').text(isBackup_bool ? 'Backup' : 'Restore');
  $('#vmbr-backup-status-wrap').toggle(isBackup_bool);
  $('#vmbr-restore-status-wrap').toggle(!isBackup_bool);
}

function vmbrH(path_str) { return HELPERS_BASE_STR + '/' + path_str; }
function vmbrGet(ep_str, data_obj) { return $.getJSON(vmbrH(ep_str), data_obj || {}); }
function vmbrPost(ep_str, data_obj) { return $.post(vmbrH(ep_str), data_obj); }

function vmbrGetSelectedServices(isRestore_bool) { const listId_str = isRestore_bool ? '#vmbr-restore-notif-list' : '#vmbr-backup-notif-list'; return $(listId_str).find('input:checked').map(function () { return $(this).val(); }).get(); }
function vmbrUpdateNotifLabel(isRestore_bool) { const services_arr = vmbrGetSelectedServices(isRestore_bool); const labelId_str = isRestore_bool ? '#vmbr-restore-notif-label' : '#vmbr-backup-notif-label'; $(labelId_str).text(services_arr.length ? services_arr.join(', ') : 'Select service(s)'); }
function vmbrFormatMissingList(arr) { if (arr.length === 1) return arr[0]; if (arr.length === 2) return arr[0] + ' and ' + arr[1]; return arr.slice(0, -1).join(', ') + ', and ' + arr[arr.length - 1]; }
function vmbrNormalizeWebhookUrl(val_str, svc_str) { val_str = val_str.trim(); if (!val_str || val_str.startsWith('https://')) return val_str; const cfg = SERVICE_CONFIG_OBJ[svc_str]; return (cfg && cfg.prefix) ? cfg.prefix + val_str : val_str; }
function vmbrValidateWebhookUrl(val_str, svc_str) { if (!val_str) return true; const cfg = SERVICE_CONFIG_OBJ[svc_str]; if (!cfg || !cfg.prefix) return true; return val_str.startsWith(cfg.prefix); }
function vmbrShowPopup(id_str, msg_str) { const $p = $('#' + id_str); $p.text(msg_str).fadeIn(150); setTimeout(() => $p.fadeOut(200, () => $p.text('').hide()), 3000); }
function vmbrShowLogToast(msg_str) { const el = document.getElementById('vmbr-log-toast'); if (!el) return; el.textContent = msg_str; el.classList.add('visible'); clearTimeout(el._hideTimer); el._hideTimer = setTimeout(() => el.classList.remove('visible'), 2000); }
function vmbrLockScheduleUI() { scheduleUILocked_bool = true; $('.schedule-action-btn').prop('disabled', true); }
function vmbrUnlockScheduleUI() { scheduleUILocked_bool = false; $('.schedule-action-btn').prop('disabled', false); }
function vmbrSetAllButtonsDisabled(disabled_bool) { $('#vmbr-backup-now-btn, #vmbr-restore-now-btn').prop('disabled', disabled_bool); document.querySelectorAll('.run-schedule-btn').forEach(b => { b.disabled = disabled_bool; }); }
function vmbrSetDot(dotId_str, isActive_bool) { const el = document.getElementById(dotId_str); if (el) el.classList.toggle('active', isActive_bool); }
function vmbrShowBanner(type_str, label_str) { if (type_str === 'restore') { $('#vmbr-restore-banner-text').text(label_str); $('#vmbr-restore-stop-toast').removeClass('visible'); $('#vmbr-restore-banner').show(); } else { $('#vmbr-backup-banner-text').text(label_str); $('#vmbr-backup-stop-toast').removeClass('visible'); $('#vmbr-backup-banner').show(); } }
function vmbrHideBanner(type_str) { if (type_str === 'restore') { $('#vmbr-restore-banner').hide(); $('#vmbr-restore-stop-toast').removeClass('visible'); } else { $('#vmbr-backup-banner').hide(); $('#vmbr-backup-stop-toast').removeClass('visible'); } }
function vmbrStopFromBanner(type_str) {
  const ep_str = type_str === 'restore' ? 'stop_restore.php' : 'stop_backup.php';
  vmbrPost(ep_str, { csrf_token: csrfToken_str }).done(function () {
    const toastId_str = type_str === 'restore' ? '#vmbr-restore-stop-toast' : '#vmbr-backup-stop-toast';
    $(toastId_str).addClass('visible'); setTimeout(() => $(toastId_str).removeClass('visible'), 3000);
  }).fail(() => vmbrAlert('Error sending stop request'));
}

// ── Save settings (without running) ──────────────────────────────────────────
function vmbrSaveBackupSettings(onSuccess_fn) {
  const vms_str = $('#vmbr-hidden-vms-backup').val();
  const dest_str = $('#vmbr-backup-destination').val().trim();
  const webhooks_obj = {};
  $('#vmbr-webhook-container-backup .vmbr-webhook-input').each(function () {
    webhooks_obj['WEBHOOK_' + $(this).data('service').toUpperCase()] = $(this).val().trim();
  });
  vmbrPost('save_settings.php', {
    VMS_TO_BACKUP: vms_str,
    BACKUP_DESTINATION: dest_str,
    BACKUPS_TO_KEEP: $('#vmbr-backup-keep').val(),
    BACKUP_OWNER: $('#vmbr-backup-owner').val(),
    DRY_RUN: $('#vmbr-backup-dry-run').val(),
    NOTIFICATIONS: document.getElementById('vmbr-backup-notif')?.value || 'no',
    NOTIFICATION_SERVICE: vmbrGetSelectedServices(false).join(','),
    WEBHOOK_DISCORD: webhooks_obj['WEBHOOK_DISCORD'] || '',
    WEBHOOK_GOTIFY: webhooks_obj['WEBHOOK_GOTIFY'] || '',
    WEBHOOK_NTFY: webhooks_obj['WEBHOOK_NTFY'] || '',
    WEBHOOK_PUSHOVER: webhooks_obj['WEBHOOK_PUSHOVER'] || '',
    WEBHOOK_SLACK: webhooks_obj['WEBHOOK_SLACK'] || '',
    PUSHOVER_USER_KEY: $('#vmbr-pushover-key').val() || '',
    csrf_token: csrfToken_str
  }).done(function (res) {
    if (res && res.status === 'ok') {
      vmbrShowPopup('vmbr-backup-popup', '✓ Settings saved!');
      if (onSuccess_fn) onSuccess_fn();
    } else {
      vmbrAlert('Failed to save settings');
    }
  }).fail(() => vmbrAlert('Error saving settings'));
}

function vmbrSaveRestoreSettings(onSuccess_fn) {
  const vms_str = $('#vmbr-hidden-vms-restore').val();
  const location_str = $('#vmbr-restore-location').val().trim();
  const dest_str = $('#vmbr-restore-destination').val().trim();
  const versions_obj = {};
  $('#vmbr-version-container select.version-select').each(function () {
    const vm_str = $(this).data('vm'); const val_str = $(this).val();
    if (vm_str && val_str) versions_obj[vm_str] = val_str;
  });
  const versionsStr_str = Object.entries(versions_obj).map(([v, r]) => `${v}=${r}`).join(',');
  const webhooks_obj = {};
  $('#vmbr-webhook-container-restore .vmbr-webhook-input').each(function () {
    webhooks_obj['WEBHOOK_' + $(this).data('service').toUpperCase() + '_RESTORE'] = $(this).val().trim();
  });
  vmbrPost('save_settings_restore.php', {
    LOCATION_OF_BACKUPS: location_str,
    VMS_TO_RESTORE: vms_str,
    VERSIONS: versionsStr_str,
    RESTORE_DESTINATION: dest_str,
    DRY_RUN_RESTORE: $('#vmbr-restore-dry-run').val(),
    NOTIFICATIONS_RESTORE: document.getElementById('vmbr-restore-notif')?.value || 'no',
    NOTIFICATION_SERVICE_RESTORE: vmbrGetSelectedServices(true).join(','),
    WEBHOOK_DISCORD_RESTORE: webhooks_obj['WEBHOOK_DISCORD_RESTORE'] || '',
    WEBHOOK_GOTIFY_RESTORE: webhooks_obj['WEBHOOK_GOTIFY_RESTORE'] || '',
    WEBHOOK_NTFY_RESTORE: webhooks_obj['WEBHOOK_NTFY_RESTORE'] || '',
    WEBHOOK_PUSHOVER_RESTORE: webhooks_obj['WEBHOOK_PUSHOVER_RESTORE'] || '',
    WEBHOOK_SLACK_RESTORE: webhooks_obj['WEBHOOK_SLACK_RESTORE'] || '',
    PUSHOVER_USER_KEY_RESTORE: $('#vmbr-pushover-key_restore').val() || '',
    csrf_token: csrfToken_str
  }).done(function (res) {
    if (res && res.status === 'ok') {
      vmbrShowPopup('vmbr-restore-popup', '✓ Settings saved!');
      if (onSuccess_fn) onSuccess_fn();
    } else {
      vmbrAlert('Failed to save settings');
    }
  }).fail(() => vmbrAlert('Error saving settings'));
}

// ── Webhook fields ────────────────────────────────────────────────────────────
function vmbrRebuildWebhookFields(isRestore_bool) {
  const containerId_str = isRestore_bool ? '#vmbr-webhook-container-restore' : '#vmbr-webhook-container-backup';
  const services_arr = vmbrGetSelectedServices(isRestore_bool);
  const container_el = $(containerId_str); container_el.empty();
  const savedWebhooks_obj = isRestore_bool ? SAVED_WEBHOOKS_RESTORE_OBJ : SAVED_WEBHOOKS_OBJ;
  const savedKey_str = isRestore_bool ? SAVED_PUSHOVER_KEY_RESTORE_STR : SAVED_PUSHOVER_KEY_STR;
  const sfx_dash_str = isRestore_bool ? '-restore' : '';
  const sfx_under_str = isRestore_bool ? '_restore' : '';
  services_arr.forEach(function (svc_str) {
    const cfg = SERVICE_CONFIG_OBJ[svc_str]; if (!cfg) return;
    if (cfg.needsUrl_bool) {
      const fldId_str = 'vmbr-webhook-' + svc_str.toLowerCase() + sfx_dash_str;
      const errId_str = 'vmbr-webhook-err-' + svc_str.toLowerCase() + sfx_dash_str;
      const saved_str = savedWebhooks_obj[svc_str.toUpperCase()] || '';
      container_el.append($(`<div class="form-pair" id="vmbr-webhook-row-${svc_str.toLowerCase()}${sfx_dash_str}"><label title="${cfg.label}">${cfg.label}:</label><div class="input-wrapper"><input type="text" id="${fldId_str}" class="short-input vmbr-webhook-input" data-service="${svc_str}" data-restore="${isRestore_bool ? '1' : '0'}" placeholder="${cfg.prefix || ''}" value="${saved_str}"><div id="${errId_str}" style="color:#f59e0b;font-size:11px;display:none;">* Invalid ${svc_str} webhook URL</div></div></div>`));
    }
    if (cfg.needsKey_bool) {
      const pkId_str = 'vmbr-pushover-key' + sfx_under_str;
      const pkErr_str = 'vmbr-pushover-key-err' + sfx_dash_str;
      container_el.append($(`<div class="form-pair" id="vmbr-pushover-row${sfx_dash_str}"><label title="Your Pushover user key from pushover.net/dashboard">Pushover User Key:</label><div class="input-wrapper"><input type="text" id="${pkId_str}" name="PUSHOVER_USER_KEY${isRestore_bool ? '_RESTORE' : ''}" class="short-input" placeholder="user key from pushover.net/dashboard" value="${savedKey_str}"><div id="${pkErr_str}" style="color:#f59e0b;font-size:11px;display:none;">* Pushover user key is required</div></div></div>`));
    }
  });
  container_el.find('.vmbr-webhook-input').on('input', function () {
    const svc_str = $(this).data('service'); const val_str = $(this).val().trim(); const rest_bool = $(this).data('restore') === '1' || $(this).data('restore') === 1;
    const errId_str = '#vmbr-webhook-err-' + svc_str.toLowerCase() + (rest_bool ? '-restore' : '');
    $(errId_str).toggle(val_str !== '' && !vmbrValidateWebhookUrl(val_str, svc_str));
  }).on('blur', function () { const svc_str = $(this).data('service'); $(this).val(vmbrNormalizeWebhookUrl($(this).val(), svc_str)).trigger('input'); });
  if (window._fbbProcessLabels) window._fbbProcessLabels(container_el);
}

function vmbrApplyNotifToggle(select_el, rowId_str, containerId_str, isRestore_bool) {
  const isYes_bool = select_el && select_el.value === 'yes'; const $row = $(rowId_str);
  if (isYes_bool) { $row.show(); if (window._fbbProcessLabels) window._fbbProcessLabels($row); vmbrRebuildWebhookFields(isRestore_bool); } else { $row.hide(); $(containerId_str).empty(); }
  vmbrUpdateNotifLabel(isRestore_bool);
}

// ── Cron helpers ──────────────────────────────────────────────────────────────
const DAY_MAP_OBJ = { Sunday: 0, Monday: 1, Tuesday: 2, Wednesday: 3, Thursday: 4, Friday: 5, Saturday: 6 };
const DAY_NAMES_ARR = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

function vmbrBuildCronFromUI() {
  const mode_str = $('#vmbr-cron-mode').val();
  switch (mode_str) {
    case 'hourly': return { valid_bool: true, expr_str: `0 */${parseInt($('#vmbr-hourly-freq').val(), 10)} * * *` };
    case 'daily': return { valid_bool: true, expr_str: `${parseInt($('#vmbr-daily-min').val(), 10)} ${parseInt($('#vmbr-daily-hour').val(), 10)} * * *` };
    case 'weekly': { const d_int = DAY_MAP_OBJ[$('#vmbr-weekly-day').val()]; return { valid_bool: true, expr_str: `${parseInt($('#vmbr-weekly-min').val(), 10)} ${parseInt($('#vmbr-weekly-hour').val(), 10)} * * ${d_int}` }; }
    case 'monthly': return { valid_bool: true, expr_str: `${parseInt($('#vmbr-monthly-min').val(), 10)} ${parseInt($('#vmbr-monthly-hour').val(), 10)} ${parseInt($('#vmbr-monthly-day').val(), 10)} * *` };
    default: return { valid_bool: false };
  }
}
function vmbrUpdateCronHidden() {
  const cron_obj = vmbrBuildCronFromUI();
  let hidden_el = document.getElementById('vmbr-cron-hidden');
  if (!hidden_el) { hidden_el = document.createElement('input'); hidden_el.type = 'hidden'; hidden_el.id = 'vmbr-cron-hidden'; hidden_el.name = 'CRON_EXPRESSION'; document.getElementById('vmbr-cron-mode-row').appendChild(hidden_el); }
  hidden_el.value = cron_obj.valid_bool ? cron_obj.expr_str : '';
}
function vmbrToggleCronOptions(mode_str) { $('#vmbr-hourly-options').toggle(mode_str === 'hourly'); $('#vmbr-daily-options').toggle(mode_str === 'daily'); $('#vmbr-weekly-options').toggle(mode_str === 'weekly'); $('#vmbr-monthly-options').toggle(mode_str === 'monthly'); vmbrUpdateCronHidden(); }
function vmbrDetectCronMode(cron_str) { if (!cron_str) return 'daily'; if (/^0 \*\/\d+ \* \* \*$/.test(cron_str)) return 'hourly'; if (/^\d+ \d+ \* \* \*$/.test(cron_str)) return 'daily'; if (/^\d+ \d+ \* \* [0-6]$/.test(cron_str)) return 'weekly'; if (/^\d+ \d+ \d+ \* \*$/.test(cron_str)) return 'monthly'; return 'daily'; }

// ── Populate cron UI fields from a cron expression ────────────────────────────
function vmbrPopulateCronFields(cron_str) {
  if (!cron_str) return;
  const mode_str = vmbrDetectCronMode(cron_str);
  $('#vmbr-cron-mode').val(mode_str).trigger('change');
  vmbrToggleCronOptions(mode_str);

  const parts_arr = cron_str.trim().split(/\s+/);
  if (parts_arr.length !== 5) return;
  const [min_s, hour_s, dom_s, , dow_s] = parts_arr;

  if (mode_str === 'hourly') {
    const m_arr = hour_s.match(/^\*\/(\d+)$/);
    if (m_arr) $('#vmbr-hourly-freq').val(m_arr[1]).trigger('change');
  } else if (mode_str === 'daily') {
    $('#vmbr-daily-hour').val(hour_s.padStart(2, '0')).trigger('change');
    $('#vmbr-daily-min').val(min_s.padStart(2, '0')).trigger('change');
  } else if (mode_str === 'weekly') {
    const dow_int = parseInt(dow_s, 10);
    if (!isNaN(dow_int) && DAY_NAMES_ARR[dow_int]) {
      $('#vmbr-weekly-day').val(DAY_NAMES_ARR[dow_int]).trigger('change');
    }
    $('#vmbr-weekly-hour').val(hour_s.padStart(2, '0')).trigger('change');
    $('#vmbr-weekly-min').val(min_s.padStart(2, '0')).trigger('change');
  } else if (mode_str === 'monthly') {
    $('#vmbr-monthly-day').val(dom_s.padStart(2, '0')).trigger('change');
    $('#vmbr-monthly-hour').val(hour_s.padStart(2, '0')).trigger('change');
    $('#vmbr-monthly-min').val(min_s.padStart(2, '0')).trigger('change');
  }
  vmbrUpdateCronHidden();
}

function vmbrCronToMinutesOfWeek(expr_str) {
  const parts_arr = expr_str.trim().split(/\s+/); if (parts_arr.length !== 5) return [];
  const [min_s, hour_s, dom_s, month_s, dow_s] = parts_arr; const mins_arr = []; const WK_INT = 7 * 24 * 60;
  const hInterval_arr = hour_s.match(/^\*\/(\d+)$/);
  if (min_s === '0' && hInterval_arr && dom_s === '*' && month_s === '*' && dow_s === '*') { const n_int = parseInt(hInterval_arr[1], 10); for (let h = 0; h < 7 * 24; h += n_int)mins_arr.push(h * 60); return mins_arr; }
  if (min_s === '0' && /^\d+$/.test(hour_s) && dom_s === '*' && month_s === '*' && dow_s === '*') { const h_int = parseInt(hour_s, 10); for (let d = 0; d < 7; d++)mins_arr.push(d * 24 * 60 + h_int * 60); return mins_arr; }
  if (min_s === '0' && /^\d+$/.test(hour_s) && dom_s === '*' && month_s === '*' && /^\d+$/.test(dow_s)) { mins_arr.push(parseInt(dow_s, 10) * 24 * 60 + parseInt(hour_s, 10) * 60); return mins_arr; }
  if (min_s === '0' && /^\d+$/.test(hour_s) && /^\d+$/.test(dom_s) && month_s === '*' && dow_s === '*') { const d_int = (parseInt(dom_s, 10) - 1) % 7; mins_arr.push(d_int * 24 * 60 + parseInt(hour_s, 10) * 60); return mins_arr; }
  return [];
}
function vmbrCheckCronConflicts(newCron_str, existing_arr, excludeId_str, threshold_int) {
  const newTimes_arr = vmbrCronToMinutesOfWeek(newCron_str); if (!newTimes_arr.length) return null;
  const WK_INT = 7 * 24 * 60;
  for (const entry of existing_arr) { if (entry.id === excludeId_str) continue; const exTimes_arr = vmbrCronToMinutesOfWeek(entry.cron); for (const nt of newTimes_arr) { for (const et of exTimes_arr) { const diff_int = Math.min(Math.abs(nt - et), WK_INT - Math.abs(nt - et)); if (diff_int < threshold_int) return entry.cron; } } }
  return null;
}

function vmbrValidatePrereqs() {
  const vms_str = $('#vmbr-hidden-vms-backup').val()?.trim(); const dest_str = $('#vmbr-backup-destination').val()?.trim();
  if (!vms_str) { vmbrAlert('Please select at least one VM for the schedule'); return false; }
  if (!dest_str) { vmbrAlert('Please select a backup destination for the schedule'); return false; }
  const services_arr = vmbrGetSelectedServices(false);
  if (services_arr.includes('Pushover') && document.getElementById('vmbr-backup-notif')?.value === 'yes') { if (!$('#vmbr-pushover-key').val().trim()) { vmbrAlert('Please enter your Pushover user key'); return false; } }
  return true;
}

// ── Select/picker wrap ────────────────────────────────────────────────────────
function vmbrWrapSelects() {
  document.querySelectorAll('#vmbr-mode-row select').forEach(function (sel_el) {
    sel_el.classList.add('vmbr-wrapped');
  });
  document.querySelectorAll('#vmbr-page select:not(.vmbr-wrapped)').forEach(function (sel_el) {
    if (sel_el.closest('.vmbr-select-wrap')) return;
    const wrap_el = document.createElement('div');
    wrap_el.className = 'vmbr-select-wrap';
    sel_el.parentNode.insertBefore(wrap_el, sel_el);
    wrap_el.appendChild(sel_el);
    sel_el.classList.add('vmbr-wrapped');
  });
  ['vmbr-backup-destination', 'vmbr-restore-location', 'vmbr-restore-destination'].forEach(function (id_str) {
    const inp_el = document.getElementById(id_str);
    if (!inp_el || inp_el.closest('.vmbr-select-wrap')) return;
    const wrap_el = document.createElement('div');
    wrap_el.className = 'vmbr-select-wrap';
    inp_el.parentNode.insertBefore(wrap_el, inp_el);
    wrap_el.appendChild(inp_el);
  });
}

// ── Schedule edit mode UI helpers ─────────────────────────────────────────────
function vmbrEnterScheduleEditMode(id_str) {
  $('#vmbr-backup-now-btn').hide();
  $('#vmbr-schedule-update-btn').show();
  $('#vmbr-schedule-btn').hide();
  $('#vmbr-schedule-cancel-edit-btn').show();
  $('#vmbr-backup-save-btn').prop('disabled', true).addClass('vmbr-btn-muted');
  $('#vmbr-cancel-edit-btn').hide();
  vmbrMarkTableEditBtn(id_str, true);
}

function vmbrExitScheduleEditMode() {
  $('#vmbr-backup-now-btn').show();
  $('#vmbr-schedule-update-btn').hide();
  $('#vmbr-schedule-btn').show();
  $('#vmbr-schedule-cancel-edit-btn').hide();
  $('#vmbr-backup-save-btn').prop('disabled', false).removeClass('vmbr-btn-muted');
  vmbrMarkTableEditBtn(null, false);
  editingScheduleId_str = null;
}

function vmbrMarkTableEditBtn(id_str, isEditing_bool) {
  $('.schedule-edit-btn').each(function () {
    const btnId_str = $(this).data('id');
    $(this).text('Edit');
    this.onclick = function () { editSchedule(btnId_str); };
    if ($(this).hasClass('tooltipstered')) {
      $(this).tooltipster('content', 'Edit schedule');
    } else {
      $(this).attr('title', 'Edit schedule');
    }
  });
  if (isEditing_bool && id_str) {
    const $btn = $(`button.schedule-edit-btn[data-id="${id_str}"]`);
    if ($btn.length) {
      $btn.text('Update');
      $btn[0].onclick = function () { vmbrScheduleJob('backup'); };
      if ($btn.hasClass('tooltipstered')) {
        $btn.tooltipster('content', 'Save changes to this schedule');
      } else {
        $btn.attr('title', 'Save changes to this schedule');
      }
    }
  }
}

// ── State ─────────────────────────────────────────────────────────────────────
let lastBackupStatus_str = null;
let lastRestoreStatus_str = null;
let lastLockSnapshot_str = null;
let lastLogSnapshot_str = null;
let lastVmList_str = '';
let lastRestoreFolderList_str = '';
let backupRunning_bool = false;
let backupReqInFlight_bool = false;
let scheduleUILocked_bool = false;
let prevBackupBanner_bool = false;
let prevRestoreBanner_bool = false;
let restoreFolderLoadInFlight_bool = false;
let versionRebuildInFlight_bool = false;
let versionRebuildTimer_id = null;
let folderPickerPath_str = '/mnt';
let folderPickerSelected_str = null;
let folderPickerTargetId_str = null;
let logAutoScroll_bool = false;
let logDebugMode_bool = false;
let editingScheduleId_str = null;
let vmbrOriginalRestoreSelection_arr = [];

// ── Log ───────────────────────────────────────────────────────────────────────
function vmbrSwitchLog(isDebug_bool) {
  logDebugMode_bool = isDebug_bool;
  logAutoScroll_bool = false;
  lastLogSnapshot_str = null;
  document.getElementById('vmbr-log-pre').scrollTop = 0;
}

function vmbrApplyLogSearch() {
  const logEl = document.getElementById('vmbr-log-pre');
  const countEl = document.getElementById('vmbr-log-search-count');
  const term_str = (document.getElementById('vmbr-log-search').value || '').trim();
  const raw_str = logEl.dataset.raw || '';
  if (!term_str) { logEl.textContent = raw_str || 'VM backup & restore log not found'; countEl.classList.remove('visible'); return; }
  const escaped_str = term_str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re_obj = new RegExp('(' + escaped_str + ')', 'gi');
  const parts_arr = raw_str.split(re_obj); let matches_int = 0; logEl.innerHTML = '';
  parts_arr.forEach(function (part_str) {
    if (re_obj.test(part_str)) { matches_int++; const mark_el = document.createElement('mark'); mark_el.className = 'log-highlight'; mark_el.textContent = part_str; logEl.appendChild(mark_el); re_obj.lastIndex = 0; }
    else { logEl.appendChild(document.createTextNode(part_str)); }
  });
  countEl.textContent = matches_int + ' match' + (matches_int !== 1 ? 'es' : '');
  countEl.classList.toggle('visible', matches_int > 0);
}

function vmbrFallbackCopy(text_str) {
  const ta_el = document.createElement('textarea'); ta_el.value = text_str; document.body.appendChild(ta_el); ta_el.select();
  try { document.execCommand('copy'); vmbrShowLogToast(logDebugMode_bool ? 'Debug log copied' : 'Log copied'); } catch (e) { vmbrAlert('Failed to copy log'); }
  document.body.removeChild(ta_el);
}

// ── Pollers ───────────────────────────────────────────────────────────────────
(function vmbrBackupStatusPoller() {
  fetch(vmbrH('backup_status_check.php'), { credentials: 'same-origin' }).then(r => r.json()).then(data => {
    if (data.status !== lastBackupStatus_str) { lastBackupStatus_str = data.status; const el = document.getElementById('vmbr-backup-status-text'); if (el) el.textContent = data.status; vmbrSetDot('vmbr-backup-dot', data.status && data.status !== 'No Backup Running' && data.status !== 'Idle'); }
  }).catch(() => { }).finally(() => setTimeout(vmbrBackupStatusPoller, (lastBackupStatus_str && lastBackupStatus_str.includes('Running')) ? POLL_FAST_MS_INT : POLL_SLOW_MS_INT));
})();

(function vmbrRestoreStatusPoller() {
  fetch(vmbrH('restore_status_check.php'), { credentials: 'same-origin' }).then(r => r.json()).then(data => {
    if (data.status !== lastRestoreStatus_str) { lastRestoreStatus_str = data.status; const el = document.getElementById('vmbr-restore-status-text'); if (el) el.textContent = data.status; vmbrSetDot('vmbr-restore-dot', data.status && data.status !== 'No Restore Running' && data.status !== 'Idle'); }
  }).catch(() => { }).finally(() => setTimeout(vmbrRestoreStatusPoller, (lastRestoreStatus_str && lastRestoreStatus_str.includes('Running')) ? POLL_FAST_MS_INT : POLL_SLOW_MS_INT));
})();

(function vmbrLockPoller() {
  fetch(vmbrH('check_lock.php')).then(r => r.json()).then(data => {
    const snapshot_str = JSON.stringify(data); if (snapshot_str === lastLockSnapshot_str) return; lastLockSnapshot_str = snapshot_str;
    const backupLocked_bool = data.locked && data.mode === 'manual'; const scheduleLocked_bool = data.locked && data.mode === 'schedule' || data.locked && data.mode === 'schedule-manual'; const restoreLocked_bool = data.locked && data.mode === 'restore'; const anyLocked_bool = !!data.locked;
    document.querySelectorAll('.run-schedule-btn').forEach(b => { b.disabled = anyLocked_bool; b.classList.toggle('disabled', anyLocked_bool); });
    if ((backupLocked_bool || scheduleLocked_bool) && !prevBackupBanner_bool) { vmbrShowBanner('backup', scheduleLocked_bool ? '⚠ Scheduled backup in progress' : '⚠ Backup in progress'); vmbrSetAllButtonsDisabled(true); prevBackupBanner_bool = true; }
    else if (!backupLocked_bool && !scheduleLocked_bool && prevBackupBanner_bool) { vmbrHideBanner('backup'); if (!prevRestoreBanner_bool) vmbrSetAllButtonsDisabled(false); prevBackupBanner_bool = false; }
    if (restoreLocked_bool && !prevRestoreBanner_bool) { vmbrShowBanner('restore', '⚠ Restore in progress'); vmbrSetAllButtonsDisabled(true); prevRestoreBanner_bool = true; }
    else if (!restoreLocked_bool && prevRestoreBanner_bool) { vmbrHideBanner('restore'); if (!prevBackupBanner_bool) vmbrSetAllButtonsDisabled(false); prevRestoreBanner_bool = false; }
  }).catch(err => console.error('[vm-backup] lock poller:', err)).finally(() => setTimeout(vmbrLockPoller, POLL_FAST_MS_INT));
})();

(function vmbrBackupRunningPoller() {
  vmbrGet('backup_status.php').done(function (res) { const running_bool = res.running === true; if (running_bool !== backupRunning_bool) { backupRunning_bool = running_bool; document.getElementById('vmbr-backup-now-btn').disabled = running_bool; } }).always(() => setTimeout(vmbrBackupRunningPoller, POLL_FAST_MS_INT));
})();
(function vmbrRestoreRunningPoller() { vmbrGet('restore_status.php').always(() => setTimeout(vmbrRestoreRunningPoller, POLL_FAST_MS_INT)); })();

(function vmbrLogPoller() {
  fetch(vmbrH('fetch_last_run_log.php') + '?debug=' + (logDebugMode_bool ? '1' : '0'))
    .then(r => r.text())
    .then(data_str => {
      const emptyMsg_str = logDebugMode_bool ? 'VM backup & restore debug log not found' : 'VM backup & restore log not found';
      const reversed_str = data_str
        ? data_str.split('\n').filter(l => l.trim()).reverse().join('\n')
        : '';
      const display_str = reversed_str || emptyMsg_str;
      if (display_str === lastLogSnapshot_str) return;
      lastLogSnapshot_str = display_str;
      const logEl = document.getElementById('vmbr-log-pre');
      logEl.dataset.raw = display_str;
      vmbrApplyLogSearch();
      if (logAutoScroll_bool) logEl.scrollTop = logEl.scrollHeight;
      vmbrUpdateLastRun(data_str);
    })
    .catch(() => {
      const msg_str = 'Error loading VM backup & restore log';
      if (msg_str !== lastLogSnapshot_str) { lastLogSnapshot_str = msg_str; const logEl = document.getElementById('vmbr-log-pre'); logEl.dataset.raw = msg_str; logEl.textContent = msg_str; }
    })
    .finally(() => setTimeout(vmbrLogPoller, POLL_FAST_MS_INT));
})();

function vmbrTimeAgo(date_obj) {
  const diff_int = Math.floor((Date.now() - date_obj.getTime()) / 1000);
  if (diff_int < 60) return '< 1 minute ago';
  const mins_int = Math.floor(diff_int / 60); if (mins_int < 60) return mins_int + ' ' + (mins_int === 1 ? 'minute' : 'minutes') + ' ago';
  const hours_int = Math.floor(mins_int / 60); if (hours_int < 24) return hours_int + ' ' + (hours_int === 1 ? 'hour' : 'hours') + ' ago';
  const days_int = Math.floor(hours_int / 24); if (days_int < 7) return days_int + ' ' + (days_int === 1 ? 'day' : 'days') + ' ago';
  const weeks_int = Math.floor(days_int / 7); if (weeks_int < 5) return weeks_int + ' ' + (weeks_int === 1 ? 'week' : 'weeks') + ' ago';
  const months_int = Math.floor(days_int / 30); return months_int + ' ' + (months_int === 1 ? 'month' : 'months') + ' ago';
}
function vmbrUpdateLastRun(logText_str) {
  const el = document.getElementById('vmbr-log-last-run'); if (!el) return;
  if (!logText_str || logText_str.includes('log not found') || logText_str.includes('Error loading')) { el.textContent = 'No last run available'; return; }
  const lines_arr = logText_str.split('\n'); let ts_str = null;
  for (const line_str of lines_arr) { if (/session finished/i.test(line_str)) { const m_arr = line_str.match(/^\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]/); if (m_arr) { ts_str = m_arr[1]; break; } } }
  if (!ts_str) { el.textContent = 'No last run available'; return; }
  const date_obj = new Date(ts_str.replace(' ', 'T')); if (isNaN(date_obj.getTime())) { el.textContent = 'No last run available'; return; }
  el.textContent = 'Last Run: ' + vmbrTimeAgo(date_obj);
}
(function vmbrLastRunRefreshPoller() { const el = document.getElementById('vmbr-log-last-run'); if (el && lastLogSnapshot_str) vmbrUpdateLastRun(lastLogSnapshot_str); setTimeout(vmbrLastRunRefreshPoller, 1000); })();

(function vmbrVmListPoller() {
  if ($('#vmbr-vm-dropdown-backup .vmbr-vm-dropdown-list').is(':visible')) return setTimeout(vmbrVmListPoller, POLL_SLOW_MS_INT);
  vmbrGet('list_vms.php').done(function (data) { const newList_str = (data.vms || []).slice().sort().join(','); if (newList_str !== lastVmList_str) { lastVmList_str = newList_str; const currentSel_str = $('#vmbr-hidden-vms-backup').val() || ''; $('#vmbr-vm-dropdown-backup').attr('data-selected', currentSel_str); vmbrLoadBackupVMs(); } }).always(() => setTimeout(vmbrVmListPoller, POLL_SLOW_MS_INT));
})();

(function vmbrRestoreFolderPoller() {
  const restorePath_str = $('#vmbr-restore-location').val().trim();
  const dropdownOpen_bool = $('#vmbr-vm-dropdown-restore .vmbr-vm-dropdown-list').is(':visible');
  if (dropdownOpen_bool || !restorePath_str) return setTimeout(vmbrRestoreFolderPoller, POLL_FAST_MS_INT);
  const currentSel_str = $('#vmbr-hidden-vms-restore').val() || '';
  vmbrGet('list_restore_folders.php', { restore_path: restorePath_str }).done(function (data) { const newList_str = (data.folders || []).slice().sort().join(','); if (newList_str !== lastRestoreFolderList_str) { lastRestoreFolderList_str = newList_str; vmbrOriginalRestoreSelection_arr = currentSel_str.split(',').map(s => s.trim()).filter(Boolean); vmbrLoadRestoreFolders(); } }).always(() => setTimeout(vmbrRestoreFolderPoller, POLL_FAST_MS_INT));
})();

(function vmbrMalformedPoller() { vmbrScanMalformed(); setTimeout(vmbrMalformedPoller, POLL_FAST_MS_INT); })();

// ── VM / folder list builders ─────────────────────────────────────────────────
function vmbrLoadBackupVMs() {
  const dropdown_el = $('#vmbr-vm-dropdown-backup'); const label_el = dropdown_el.find('.vmbr-dropdown-label'); const list_el = dropdown_el.find('.vmbr-vm-dropdown-list');
  const selected_arr = (dropdown_el.attr('data-selected') || '').split(',').map(s => s.trim()).filter(Boolean);
  dropdown_el.removeClass('disabled'); list_el.hide();
  vmbrGet('list_vms.php').done(function (data) {
    list_el.empty();
    if (!data.vms || !data.vms.length) { list_el.append('<div>No VMs found</div>'); label_el.text('No VMs available'); dropdown_el.addClass('disabled'); $('#vmbr-hidden-vms-backup').val(''); return; }
    data.vms.forEach(vm_str => { const id_str = 'vmchk-' + vm_str.replace(/\s+/g, '_'); const item_el = $(`<div><label><input type="checkbox" value="${vm_str}" id="${id_str}"> ${vm_str}</label></div>`); if (selected_arr.includes(vm_str)) item_el.find('input').prop('checked', true); list_el.append(item_el); });
    vmbrUpdateBackupVmLabel();
  });
}
function vmbrUpdateBackupVmLabel() {
  const checked_arr = $('#vmbr-vm-dropdown-backup .vmbr-vm-dropdown-list input:checked').map(function () { return $(this).val(); }).get();
  $('#vmbr-vm-dropdown-backup .vmbr-dropdown-label').text(checked_arr.length ? checked_arr.join(', ') : 'Select VM(s)');
  $('#vmbr-hidden-vms-backup').val(checked_arr.join(','));
}

function vmbrLoadRestoreFolders() {
  if (restoreFolderLoadInFlight_bool) return; restoreFolderLoadInFlight_bool = true;
  const currentChecked_arr = $('#vmbr-vm-dropdown-restore .vmbr-vm-dropdown-list input:checked').map(function () { return $(this).val(); }).get();
  if (currentChecked_arr.length) vmbrOriginalRestoreSelection_arr = currentChecked_arr;
  const dropdown_el = $('#vmbr-vm-dropdown-restore'); const list_el = dropdown_el.find('.vmbr-vm-dropdown-list'); const label_el = dropdown_el.find('.vmbr-dropdown-label'); const restorePath_str = $('#vmbr-restore-location').val().trim();
  list_el.empty();
  function noFolders(msg_str) { dropdown_el.addClass('disabled').removeClass('active'); list_el.hide(); label_el.text(msg_str); $('#vmbr-hidden-vms-restore').val(''); $('#vmbr-version-wrapper').hide(); $('#vmbr-version-container').empty(); restoreFolderLoadInFlight_bool = false; }
  if (!restorePath_str) { noFolders('No backups at this location'); return; }
  vmbrGet('list_restore_folders.php', { restore_path: restorePath_str }).done(function (data) {
    if (!data.folders || !data.folders.length) { noFolders('No backups at this location'); return; }
    dropdown_el.removeClass('disabled active'); list_el.hide();
    const stillValid_arr = [];
    data.folders.forEach(folder_str => { const id_str = 'vmrestore-' + folder_str.replace(/\s+/g, '_'); const item_el = $(`<div><label><input type="checkbox" value="${folder_str}" id="${id_str}"> ${folder_str}</label></div>`); if (vmbrOriginalRestoreSelection_arr.includes(folder_str)) { item_el.find('input').prop('checked', true); stillValid_arr.push(folder_str); } list_el.append(item_el); });
    if (stillValid_arr.length) { label_el.text(stillValid_arr.join(', ')); $('#vmbr-hidden-vms-restore').val(stillValid_arr.join(',')); } else { label_el.text('Select VM(s)'); $('#vmbr-hidden-vms-restore').val(''); }
    vmbrScheduleVersionRebuild();
  }).fail(() => noFolders('Error loading backups')).always(() => { restoreFolderLoadInFlight_bool = false; });
}

function vmbrScheduleVersionRebuild() { clearTimeout(versionRebuildTimer_id); versionRebuildTimer_id = setTimeout(vmbrDoRebuildVersionFields, 150); }

function vmbrDoRebuildVersionFields() {
  if (versionRebuildInFlight_bool) { versionRebuildTimer_id = setTimeout(vmbrDoRebuildVersionFields, 150); return; }
  const container_el = $('#vmbr-version-container'); const wrapper_el = $('#vmbr-version-wrapper');
  container_el.empty(); $('#vmbr-malformed-container').empty();
  const restorePath_str = $('#vmbr-restore-location').val().trim();
  if (!restorePath_str) { wrapper_el.hide(); return; }
  const selectedVMs_arr = ($('#vmbr-hidden-vms-restore').val() || '').split(',').map(s => s.trim()).filter(Boolean);
  if (!selectedVMs_arr.length) { wrapper_el.hide(); return; }
  wrapper_el.show(); versionRebuildInFlight_bool = true;
  let pending_int = selectedVMs_arr.length; const vmData_obj = {};
  selectedVMs_arr.forEach(vm_str => {
    vmbrGet('get_vm_versions.php', { vm: vm_str, restore_path: restorePath_str }).done(function (versions_arr) { vmData_obj[vm_str] = versions_arr; }).always(function () {
      pending_int--; if (pending_int > 0) return;
      selectedVMs_arr.forEach(vm_str => {
        const versions_arr = vmData_obj[vm_str] || []; const valid_arr = versions_arr.filter(v => !v.malformed);
        const field_el = $(`<div class="form-pair vmbr-version-field"><label style="color:var(--c-label) !important;font-weight:600 !important;" title="Select which backup version to restore for ${vm_str}">Version (${vm_str}):</label><span><select name="VERSION_${vm_str}" data-vm="${vm_str}" class="version-select"></select></span></div>`);
        const select_el = field_el.find('select');
        if (!valid_arr.length) { const msg_str = versions_arr.length ? 'No backups with all 3 files exist' : 'No backups found'; select_el.prop('disabled', true).append(`<option style="color:#888;">${msg_str}</option>`); }
        else { valid_arr.forEach((v_obj, idx_int) => { let lbl_str = v_obj.display; if (idx_int === 0) lbl_str += ' (LATEST)'; if (valid_arr.length > 1 && idx_int === valid_arr.length - 1) lbl_str += ' (OLDEST)'; select_el.append(`<option value="${v_obj.raw}">${lbl_str}</option>`); }); select_el.val(valid_arr[0].raw).prop('disabled', false); }
        container_el.append(field_el);
      });
      if (window._fbbProcessLabels) window._fbbProcessLabels(container_el);
      vmbrWrapSelects && vmbrWrapSelects();
      versionRebuildInFlight_bool = false;
    });
  });
}

$(document).on('focus', '.version-select', function () {
  const select_el = $(this); const vm_str = select_el.data('vm'); const restorePath_str = $('#vmbr-restore-location').val().trim();
  if (!vm_str || !restorePath_str) return; const currentVal_str = select_el.val();
  vmbrGet('get_vm_versions.php', { vm: vm_str, restore_path: restorePath_str }).done(function (versions_arr) {
    select_el.empty(); const valid_arr = (versions_arr || []).filter(v => !v.malformed);
    if (!valid_arr.length) { const msg_str = versions_arr.length ? 'No backups with all 3 files exist' : 'No backups found'; select_el.prop('disabled', true).append(`<option style="color:#888;">${msg_str}</option>`); }
    else { valid_arr.forEach((v_obj, idx_int) => { let lbl_str = v_obj.display; if (idx_int === 0) lbl_str += ' (LATEST)'; if (valid_arr.length > 1 && idx_int === valid_arr.length - 1) lbl_str += ' (OLDEST)'; select_el.append(`<option value="${v_obj.raw}">${lbl_str}</option>`); }); select_el.val(valid_arr.some(v => v.raw === currentVal_str) ? currentVal_str : valid_arr[0].raw); select_el.prop('disabled', false); }
  });
});

function vmbrScanMalformed() {
  const restorePath_str = $('#vmbr-restore-location').val().trim(); if (!restorePath_str) return;
  vmbrGet('scan_malformed_backups.php', { restore_path: restorePath_str }).done(function (data_arr) {
    if (!data_arr || !data_arr.length) { $('#vmbr-malformed-container').empty(); return; }
    let msg_str = '';
    if (data_arr.length === 1) { const b = data_arr[0]; msg_str = `⚠ ${b.vm} — Backup ${b.backup} is missing ${vmbrFormatMissingList(b.missing)}<br>This backup will not be included to be restored`; }
    else { msg_str = '⚠ Missing files:<br>'; data_arr.forEach(b => { msg_str += `${b.vm} - ${b.backup} - ${vmbrFormatMissingList(b.missing)}<br>`; }); msg_str += 'These backups will not be included to be restored'; }
    $('#vmbr-malformed-container').html(`<div>${msg_str}</div>`);
  });
}

// ── Folder picker ─────────────────────────────────────────────────────────────
function vmbrShowFolderToast(msg_str) {
  const t = document.getElementById('vmbr-folder-toast'); if (!t) return;
  t.textContent = msg_str; t.classList.add('visible');
  clearTimeout(t._timer); t._timer = setTimeout(() => t.classList.remove('visible'), 2000);
}

function vmbrLoadFolders(path_str) {
  document.getElementById('vmbr-create-folder-bar').style.display = 'none';
  document.getElementById('vmbr-new-folder-name').value = '';

  vmbrGet('list_folders.php', { path: path_str, field: folderPickerTargetId_str }).done(function (data) {
    folderPickerPath_str = data.current; folderPickerSelected_str = null;
    const parts_arr = data.current.split('/').filter(p => p !== ''); let buildPath_str = '';
    const bc_str = parts_arr.map((part_str, idx_int) => { buildPath_str += '/' + part_str; const sep_str = idx_int < parts_arr.length - 1 ? ' / ' : ''; return `<span class="vmbr-bc-part" data-path="${buildPath_str}" style="cursor:pointer;">${part_str}</span>${sep_str}`; }).join('');
    $('#vmbr-folder-breadcrumb').html(bc_str);
    let html_str = '';
    if (data.parent) html_str += `<div class="vmbr-folder-item vmbr-browse-row" data-path="${data.parent}" style="cursor:pointer;display:flex;align-items:center;">.. Up Directory</div>`;
    data.folders.forEach(f_obj => { const dis_str = f_obj.selectable ? '' : 'disabled'; const ops_str = f_obj.selectable ? '' : 'style="opacity:0.35;"'; html_str += `<div class="vmbr-folder-item vmbr-browse-row" data-path="${f_obj.path}" style="display:flex;align-items:center;gap:0px;"><label class="vmbr-folder-check-label" style="display:flex;align-items:center;cursor:pointer;padding:9px 2px 4px 4px;"><input type="checkbox" class="vmbr-folder-checkbox" value="${f_obj.path}" ${dis_str} ${ops_str}></label><span class="vmbr-folder-name-label" style="flex:1;cursor:pointer;">${f_obj.name}</span></div>`; });
    $('#vmbr-folder-list').html(html_str);
    $('.vmbr-bc-part').off('click').on('click', function () { vmbrLoadFolders($(this).data('path')); });
    $('.vmbr-browse-row').off('click').on('click', function (e) { if ($(e.target).closest('.vmbr-folder-check-label,.vmbr-folder-name-label').length) return; vmbrLoadFolders($(this).data('path')); });
    $('.vmbr-folder-name-label').off('click').on('click', function () { vmbrLoadFolders($(this).closest('.vmbr-browse-row').data('path')); });
    $('.vmbr-folder-check-label').off('click').on('click', function (e) { e.stopPropagation(); });
    $('.vmbr-folder-checkbox').off('change').on('change', function (e) { if (this.disabled) return; $('.vmbr-folder-checkbox').not(this).prop('checked', false); folderPickerSelected_str = this.checked ? $(this).val() : null; e.stopPropagation(); });
  });
}

function vmbrApplyPath(selectedPath_str, targetId_str) {
  $('#' + targetId_str).val(selectedPath_str).trigger('input').trigger('change');
  $('#vmbr-folder-picker-modal').hide();
}

// ── Backup/Restore now ────────────────────────────────────────────────────────
$('#vmbr-backup-now-btn').on('click', function () {
  if (backupReqInFlight_bool) return;
  const vms_str = $('#vmbr-hidden-vms-backup').val(); const dest_str = $('#vmbr-backup-destination').val().trim();
  if (!vms_str) { vmbrAlert('Please select at least one VM to backup'); return; }
  if (!dest_str) { vmbrAlert('Please select a backup destination'); return; }
  const services_arr = vmbrGetSelectedServices(false);
  if (services_arr.includes('Pushover') && document.getElementById('vmbr-backup-notif')?.value === 'yes') { if (!$('#vmbr-pushover-key').val().trim()) { vmbrAlert('Please enter your Pushover user key'); return; } }
  backupReqInFlight_bool = true;
  vmbrSaveBackupSettings(function () {
    $.get(vmbrH('backup.php'), { csrf_token: csrfToken_str }).done(function (res2) {
      if (res2 && res2.status === 'ok') console.log('[vm-backup] started PID:', res2.pid);
      else vmbrAlert(res2.message || 'Failed to start backup');
    }).fail(() => vmbrAlert('Error starting backup'));
    backupReqInFlight_bool = false;
  });
  setTimeout(() => { backupReqInFlight_bool = false; }, 5000);
});

$('#vmbr-restore-now-btn').on('click', function () {
  const vms_str = $('#vmbr-hidden-vms-restore').val(); const location_str = $('#vmbr-restore-location').val().trim(); const dest_str = $('#vmbr-restore-destination').val().trim();
  if (!vms_str) { vmbrAlert('Please select at least one VM to restore'); return; }
  if (!location_str) { vmbrAlert('Please set location of backups'); return; }
  if (!dest_str) { vmbrAlert('Please set a restore destination'); return; }
  const services_arr = vmbrGetSelectedServices(true);
  if (services_arr.includes('Pushover') && document.getElementById('vmbr-restore-notif')?.value === 'yes') { if (!$('#vmbr-pushover-key_restore').val().trim()) { vmbrAlert('Please enter your Pushover user key'); return; } }
  if ($('#vmbr-restore-now-btn').prop('disabled')) return;
  vmbrSaveRestoreSettings(function () {
    $.get(vmbrH('restore.php'), { csrf_token: csrfToken_str }).done(function (res2) {
      if (res2 && res2.status === 'ok') console.log('[vm-backup] restore started PID:', res2.pid);
      else vmbrAlert(res2.message || 'Failed to start restore');
    }).fail(() => vmbrAlert('Error starting restore'));
  });
});

// ── Schedule CRUD ─────────────────────────────────────────────────────────────
function vmbrLoadSchedules(force_bool) {
  if (scheduleUILocked_bool && !force_bool) return $.Deferred().resolve().promise();
  return $.get(vmbrH('schedule_list.php'), function (html_str) { $('#vmbr-schedule-list').html(html_str); const $tbl = $('#vmbr-schedule-list table'); $tbl.removeAttr('style'); $tbl.find('thead tr, th').removeAttr('style'); $tbl.find('tbody tr').each(function () { $(this).removeAttr('style'); $(this).find('td').removeAttr('style'); }); }).always(vmbrUnlockScheduleUI);
}

async function vmbrScheduleJob(type_str) {
  if (!vmbrValidatePrereqs()) return; if (scheduleUILocked_bool) return; vmbrLockScheduleUI();
  const cron_obj = vmbrBuildCronFromUI(); if (!cron_obj.valid_bool) { vmbrUnlockScheduleUI(); vmbrAlert('Invalid cron expression'); return; }
  const existing_arr = await vmbrGet('schedule_cron_check.php');
  const conflict_str = vmbrCheckCronConflicts(cron_obj.expr_str, existing_arr, editingScheduleId_str, 15);
  if (conflict_str) { vmbrUnlockScheduleUI(); vmbrAlert('This schedule is within 15 minutes of an existing schedule (' + conflict_str + '). Please choose a different time.'); return; }
  const settings_obj = {}; $('input[name], select[name]').each(function () { settings_obj[this.name] = $(this).val(); });
  const url_str = editingScheduleId_str ? 'schedule_update.php' : 'schedule_create.php';
  $.ajax({
    type: 'POST', url: vmbrH(url_str), data: { id: editingScheduleId_str, type: type_str, cron: cron_obj.expr_str, settings: settings_obj, csrf_token: csrfToken_str },
    success: function () { vmbrExitScheduleEditMode(); vmbrLoadSchedules(true); vmbrShowPopup('vmbr-backup-popup', '✓ Schedule saved!'); },
    error: function (xhr) { vmbrUnlockScheduleUI(); if (xhr.status === 409) vmbrAlert('Duplicate schedule detected!'); else vmbrAlert('Error saving schedule: ' + xhr.responseText); }
  });
}

function editSchedule(id_str) {
  if (scheduleUILocked_bool) return; vmbrLockScheduleUI();
  vmbrGet('schedule_load.php', { id: id_str }).done(function (s_obj) {
    const settings_obj = s_obj.SETTINGS || {};
    for (const k_str in settings_obj) {
      const el_obj = $('[name="' + k_str + '"]');
      if (!el_obj.length) continue;
      if (el_obj.is(':checkbox')) el_obj.prop('checked', settings_obj[k_str] == 1 || settings_obj[k_str] === true);
      else if (el_obj.is(':radio')) $('[name="' + k_str + '"][value="' + settings_obj[k_str] + '"]').prop('checked', true);
      else el_obj.val(settings_obj[k_str]).trigger('change');
      if (k_str === 'VMS_TO_BACKUP') $('#vmbr-vm-dropdown-backup').attr('data-selected', settings_obj[k_str]);
    }
    vmbrPopulateCronFields(s_obj.CRON || '');
    editingScheduleId_str = id_str;
    vmbrLoadBackupVMs();
    vmbrEnterScheduleEditMode(id_str);
    vmbrUnlockScheduleUI();
  }).fail(function () {
    vmbrUnlockScheduleUI();
    vmbrAlert('Failed to load schedule');
  });
}

function deleteSchedule(id_str) {
  if (scheduleUILocked_bool) return;
  vmbrConfirm('Delete this schedule?', function () {
    vmbrLockScheduleUI();
    vmbrPost('schedule_delete.php', { id: id_str, csrf_token: csrfToken_str }).always(() => vmbrLoadSchedules(true));
  });
}

function runScheduleBackup(id_str, btn_el) {
  if (scheduleUILocked_bool) return;
  vmbrConfirm('Are you sure you want to run this backup now?', function () {
    vmbrLockScheduleUI(); btn_el.disabled = true;
    const origText_str = btn_el.textContent; const origTitle_str = btn_el.getAttribute('title') || 'Run schedule'; btn_el.textContent = 'Running…';
    // Use schedule_run_manual.php — has full CSRF validation, designed for UI-triggered runs.
    // run_schedule.php is reserved for cron/CLI invocation via argv[1].
    vmbrPost('schedule_run_manual.php', { id: id_str, csrf_token: csrfToken_str }).done(function (res) {
      if (!res.started) { vmbrAlert('Failed to start backup'); btn_el.disabled = false; btn_el.textContent = origText_str; vmbrUnlockScheduleUI(); return; }
      vmbrShowBanner('backup', '⚠ Scheduled backup in progress'); vmbrSetAllButtonsDisabled(true); prevBackupBanner_bool = true;
      (function waitForUnlock() { vmbrGet('check_lock.php').done(function (data) { if (!data.locked) { btn_el.textContent = origText_str; btn_el.setAttribute('title', origTitle_str); btn_el.onclick = function () { runScheduleBackup(id_str, btn_el); }; vmbrHideBanner('backup'); prevBackupBanner_bool = false; vmbrSetAllButtonsDisabled(false); vmbrUnlockScheduleUI(); return; } setTimeout(waitForUnlock, POLL_FAST_MS_INT); }); })();
    }).fail(function (xhr, status_str, err_str) { vmbrAlert('Failed to start backup: ' + (xhr.responseJSON?.error || err_str)); btn_el.disabled = false; btn_el.textContent = origText_str; vmbrUnlockScheduleUI(); });
  });
}

function toggleSchedule(id_str, isEnabled_bool) {
  if (scheduleUILocked_bool) return;
  vmbrConfirm(isEnabled_bool ? 'Disable this schedule?' : 'Enable this schedule?', function () {
    vmbrLockScheduleUI();
    vmbrPost('schedule_toggle.php', { id: id_str, csrf_token: csrfToken_str }).always(() => vmbrLoadSchedules(true));
  });
}

// ── DOM ready ─────────────────────────────────────────────────────────────────
$(document).ready(function () {
  vmbrSwitchMode('backup');

  const page_el = document.getElementById('vmbr-page');
  function vmbrZeroMargins() { if (!page_el) return; const cs_el = page_el.parentElement; const tab_el = cs_el ? cs_el.parentElement : null; if (cs_el) cs_el.style.setProperty('margin-top', '0', 'important'); if (tab_el) tab_el.style.setProperty('margin-top', '0', 'important'); page_el.style.setProperty('margin-top', '0', 'important'); }
  vmbrZeroMargins();
  let zeroAttempts_int = 0;
  const zeroInterval_id = setInterval(function () { vmbrZeroMargins(); if (++zeroAttempts_int >= 8) clearInterval(zeroInterval_id); }, 250);

  const savedRestoreSel_str = (typeof VMBR_SAVED_VMS_TO_RESTORE !== 'undefined') ? VMBR_SAVED_VMS_TO_RESTORE : '';
  vmbrOriginalRestoreSelection_arr = savedRestoreSel_str.split(',').map(s => s.trim()).filter(Boolean);

  const ownerSel_el = $('#vmbr-backup-owner'); const ownerSelected_str = ownerSel_el.data('selected') || 'nobody';
  vmbrGet('list_users_group100.php').done(function (data) { ownerSel_el.empty(); (data.users || []).forEach(user_str => { ownerSel_el.append($('<option>', { value: user_str, text: user_str, selected: user_str === ownerSelected_str })); }); });

  const backupDropdown_el = $('#vmbr-vm-dropdown-backup'); const backupList_el = backupDropdown_el.find('.vmbr-vm-dropdown-list');
  backupDropdown_el.find('.vmbr-dropdown-label').on('click', function (e) { if (backupDropdown_el.hasClass('disabled')) return; e.stopPropagation(); backupList_el.toggle(); backupDropdown_el.toggleClass('active', backupList_el.is(':visible')); });
  $(document).on('click', function (e) { if (!$(e.target).closest('#vmbr-vm-dropdown-backup').length) { backupList_el.hide(); backupDropdown_el.removeClass('active'); } });
  backupList_el.on('change', 'input[type=checkbox]', vmbrUpdateBackupVmLabel);
  vmbrLoadBackupVMs();

  const restoreDropdown_el = $('#vmbr-vm-dropdown-restore'); const restoreList_el = restoreDropdown_el.find('.vmbr-vm-dropdown-list');
  restoreDropdown_el.on('click', function (e) { if (restoreDropdown_el.hasClass('disabled')) return; e.stopPropagation(); restoreList_el.toggle(); restoreDropdown_el.toggleClass('active', restoreList_el.is(':visible')); });
  $(document).on('click', function (e) { if (!$(e.target).closest('#vmbr-vm-dropdown-restore').length) { restoreList_el.hide(); restoreDropdown_el.removeClass('active'); } });
  restoreList_el.on('click', 'input,label', function (e) { e.stopPropagation(); });
  restoreList_el.on('change', 'input[type=checkbox]', function () { const checked_arr = restoreList_el.find('input:checked').map(function () { return $(this).val(); }).get(); restoreDropdown_el.find('.vmbr-dropdown-label').text(checked_arr.length ? checked_arr.join(', ') : 'Select VM(s)'); $('#vmbr-hidden-vms-restore').val(checked_arr.join(',')); vmbrScheduleVersionRebuild(); });

  $('#vmbr-notif-service-backup').on('click', function (e) { e.stopPropagation(); $('#vmbr-backup-notif-list').toggle(); });
  $('#vmbr-notif-service-restore').on('click', function (e) { e.stopPropagation(); $('#vmbr-restore-notif-list').toggle(); });
  $('#vmbr-backup-notif-list, #vmbr-restore-notif-list').on('click', function (e) { e.stopPropagation(); });
  $(document).on('click', function (e) { if (!$(e.target).closest('#vmbr-notif-service-backup').length) $('#vmbr-backup-notif-list').hide(); if (!$(e.target).closest('#vmbr-notif-service-restore').length) $('#vmbr-restore-notif-list').hide(); });
  $('#vmbr-backup-notif-list').on('change', 'input[type=checkbox]', function () { vmbrUpdateNotifLabel(false); vmbrRebuildWebhookFields(false); });
  $('#vmbr-restore-notif-list').on('change', 'input[type=checkbox]', function () { vmbrUpdateNotifLabel(true); vmbrRebuildWebhookFields(true); });

  const notifBackup_el = document.getElementById('vmbr-backup-notif'); const notifRestore_el = document.getElementById('vmbr-restore-notif');
  function toggleBackup() { vmbrApplyNotifToggle(notifBackup_el, '#vmbr-backup-notif-service-row', '#vmbr-webhook-container-backup', false); }
  function toggleRestore() { vmbrApplyNotifToggle(notifRestore_el, '#vmbr-restore-notif-service-row', '#vmbr-webhook-container-restore', true); }
  toggleBackup(); toggleRestore();
  if (notifBackup_el) notifBackup_el.addEventListener('change', toggleBackup);
  if (notifRestore_el) notifRestore_el.addEventListener('change', toggleRestore);

  let locationChangeTimer_id = null; let lastRestoreLocation_str = $('#vmbr-restore-location').val().trim();
  $('#vmbr-restore-location').on('input blur change', function () { const newVal_str = $(this).val().trim(); if (newVal_str === lastRestoreLocation_str) return; lastRestoreLocation_str = newVal_str; clearTimeout(locationChangeTimer_id); locationChangeTimer_id = setTimeout(function () { vmbrLoadRestoreFolders(); vmbrScanMalformed(); }, 300); });

  const cronMode_el = document.getElementById('vmbr-cron-mode');
  if (cronMode_el) { vmbrToggleCronOptions(cronMode_el.value); cronMode_el.addEventListener('change', e => vmbrToggleCronOptions(e.target.value));['#vmbr-hourly-freq', '#vmbr-daily-hour', '#vmbr-daily-min', '#vmbr-weekly-day', '#vmbr-weekly-hour', '#vmbr-weekly-min', '#vmbr-monthly-day', '#vmbr-monthly-hour', '#vmbr-monthly-min'].forEach(sel_str => { $(sel_str).on('change', vmbrUpdateCronHidden); }); }

  vmbrLoadSchedules();
  $(document).on('click', '#vmbr-schedule-btn', function () { vmbrScheduleJob('backup'); });
  $(document).on('click', '#vmbr-schedule-update-btn', function () { vmbrScheduleJob('backup'); });

  $('#vmbr-backup-save-btn').on('click', function () { vmbrSaveBackupSettings(); });
  $('#vmbr-restore-save-btn').on('click', function () { vmbrSaveRestoreSettings(); });

  $('#vmbr-schedule-cancel-edit-btn').on('click', function () {
    vmbrExitScheduleEditMode();
    vmbrLoadSchedules(true);
  });

  // Legacy cancel-edit button (kept for safety)
  $('#vmbr-cancel-edit-btn').on('click', function () {
    vmbrExitScheduleEditMode();
    vmbrLoadSchedules(true);
  });

  $('input[data-picker-title]').on('click', function () {
    folderPickerTargetId_str = $(this).attr('id');
    $('#vmbr-folder-picker-title').text($(this).data('picker-title'));
    $('#vmbr-folder-picker-modal').show();
    const saved_str = $(this).val();
    vmbrLoadFolders(saved_str && saved_str.startsWith('/mnt') ? saved_str : '/mnt');
  });
  $('#vmbr-folder-close-btn').on('click', function () {
    document.getElementById('vmbr-create-folder-bar').style.display = 'none';
    document.getElementById('vmbr-new-folder-name').value = '';
    $('#vmbr-folder-picker-modal').hide();
  });
  $('#vmbr-folder-confirm-btn').off('click').on('click', function (e) {
    e.preventDefault();
    if (!folderPickerSelected_str || !folderPickerTargetId_str) return;
    vmbrApplyPath(folderPickerSelected_str, folderPickerTargetId_str);
  });
  $('#vmbr-folder-create-btn').on('click', function () {
    const bar = document.getElementById('vmbr-create-folder-bar');
    bar.style.display = 'flex';
    document.getElementById('vmbr-new-folder-name').value = '';
    document.getElementById('vmbr-new-folder-name').focus();
  });
  $('#vmbr-new-folder-cancel-btn').on('click', function () {
    document.getElementById('vmbr-create-folder-bar').style.display = 'none';
    document.getElementById('vmbr-new-folder-name').value = '';
  });
  $('#vmbr-new-folder-ok-btn').on('click', function () {
    const name_str = document.getElementById('vmbr-new-folder-name').value.trim(); if (!name_str) return;
    vmbrPost('create_folder.php', { path: folderPickerPath_str, name: name_str, csrf_token: csrfToken_str }).done(function (res) {
      if (res.success) { document.getElementById('vmbr-create-folder-bar').style.display = 'none'; document.getElementById('vmbr-new-folder-name').value = ''; vmbrShowFolderToast('✅ Folder created'); vmbrLoadFolders(folderPickerPath_str); }
      else vmbrAlert(res.error || 'Failed to create folder');
    }, 'json');
  });
  document.getElementById('vmbr-new-folder-name')?.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') document.getElementById('vmbr-new-folder-ok-btn').click();
    if (e.key === 'Escape') document.getElementById('vmbr-new-folder-cancel-btn').click();
  });

  const logSearchEl_el = document.getElementById('vmbr-log-search'); const logSearchClear_el = document.getElementById('vmbr-log-search-clear');
  function vmbrUpdateSearchClear() { logSearchClear_el.style.display = logSearchEl_el.value ? 'flex' : 'none'; }
  logSearchClear_el.addEventListener('mousedown', function (e) { e.preventDefault(); logSearchEl_el.value = ''; vmbrApplyLogSearch(); vmbrUpdateSearchClear(); logSearchEl_el.focus(); });
  logSearchEl_el.addEventListener('input', function () { vmbrApplyLogSearch(); vmbrUpdateSearchClear(); });

  const logAutoBtn_el = document.getElementById('vmbr-log-autoscroll-btn'); const logTopBtn_el = document.getElementById('vmbr-log-scroll-top-btn');
  logAutoBtn_el.addEventListener('click', function () { logAutoScroll_bool = !logAutoScroll_bool; if (logAutoScroll_bool) { const logEl = document.getElementById('vmbr-log-pre'); logEl.scrollTop = logEl.scrollHeight; } });
  logTopBtn_el.addEventListener('click', function () { logAutoScroll_bool = false; document.getElementById('vmbr-log-pre').scrollTop = 0; });
  document.getElementById('vmbr-log-pre').addEventListener('scroll', function () { if (this.scrollHeight - this.scrollTop - this.clientHeight < 8) return; logAutoScroll_bool = false; });

  document.getElementById('vmbr-log-clear-btn').addEventListener('click', function () {
    const label_str = logDebugMode_bool ? 'debug log' : 'backup & restore log';
    vmbrConfirm('Are you sure you want to clear the ' + label_str + '?', function () {
      fetch(vmbrH('clear_log.php'), { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-TOKEN': csrfToken_str }, body: 'log=last&debug=' + (logDebugMode_bool ? '1' : '0') + '&csrf_token=' + encodeURIComponent(csrfToken_str) })
        .then(r => r.json()).then(data => { if (data.ok) { const logEl = document.getElementById('vmbr-log-pre'); logEl.dataset.raw = ''; logEl.textContent = ''; lastLogSnapshot_str = ''; document.getElementById('vmbr-log-search-count').classList.remove('visible'); vmbrShowLogToast(logDebugMode_bool ? 'Debug log cleared' : 'Log cleared'); } }).catch(() => vmbrAlert('Failed to clear log'));
    });
  });

  document.getElementById('vmbr-log-copy-btn').addEventListener('click', function () {
    const logEl = document.getElementById('vmbr-log-pre'); const text_str = logEl.dataset.raw || logEl.textContent || '';
    if (!text_str.trim() || text_str.includes('log not found')) return;
    if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(text_str).then(() => vmbrShowLogToast(logDebugMode_bool ? 'Debug log copied' : 'Copied')).catch(() => vmbrFallbackCopy(text_str)); } else { vmbrFallbackCopy(text_str); }
  });

  setTimeout(vmbrScheduleVersionRebuild, 50); setTimeout(vmbrScanMalformed, 100); vmbrLoadRestoreFolders();
  if (typeof caPluginUpdateCheck === 'function') caPluginUpdateCheck('vm-backup-and-restore.plg', { name: 'vm-backup-and-restore' });

  vmbrWrapSelects();
  const _origRebuild = vmbrRebuildWebhookFields;
  window.vmbrRebuildWebhookFields = function (isRestore_bool) {
    _origRebuild(isRestore_bool);
    setTimeout(vmbrWrapSelects, 50);
  };
});

// ── Inline help system ────────────────────────────────────────────────────────
$(document).ready(function () {
  let _fbbLastClick_int = 0; let _fbbF1Open_bool = false;

  function attachHelp($trigger, helpText_str, $insertAfter) {
    const helpId_str = 'fbb-help-' + Math.random().toString(36).substr(2, 9);
    const $helpDiv = $('<div class="fbb-help-text" id="' + helpId_str + '" style="display:none;">' + helpText_str + '</div>');
    $insertAfter.after($helpDiv); $helpDiv.data('fbb-guard', $insertAfter); $trigger.addClass('fbb-has-help');
    $trigger.on('click', function () { _fbbLastClick_int = Date.now(); const $h = $('#' + helpId_str); $h.is(':visible') ? $h.slideUp(150) : $h.slideDown(150); });
  }
  window._fbbAttachHelp = attachHelp;

  function processHelpLabels($scope) {
    $scope.find('label[title]').each(function () { const $label = $(this); const helpText_str = $label.attr('title'); if (!helpText_str || $label.hasClass('fbb-has-help')) return; $label.removeAttr('title'); const $formPair = $label.closest('.form-pair'); attachHelp($label, helpText_str, $formPair.length ? $formPair : $label); });
    $scope.find('span[title]').each(function () { const $span = $(this); if ($span.children('button').length) return; if ($span.hasClass('vmbr-status-label')) { const helpText_str = $span.attr('title'); if (!helpText_str || $span.hasClass('fbb-has-help')) return; $span.removeAttr('title'); const $statusRow = $span.closest('.vmbr-status-row'); attachHelp($span, helpText_str, $statusRow.length ? $statusRow : $span); return; } $span.removeAttr('title').removeAttr('class'); });
  }
  window._fbbProcessLabels = processHelpLabels;
  processHelpLabels($(document));

  const $modeRow = $('#vmbr-mode-row');
  if ($('#vmbr-plugin-label').length) attachHelp($('#vmbr-plugin-label'), 'Easily switch between your installed jcofer555 plugins', $modeRow);
  attachHelp($('#vmbr-mode-label'), 'Switch between modes', $modeRow);
  attachHelp($('#vmbr-debug-log-label'), 'Enable to view the debug log', $('#vmbr-debug-log-label').closest('.vmbr-log-toolbar'));

  $(document).on('keydown', function (e) { if (e.key !== 'F1') return; e.preventDefault(); if (_fbbF1Open_bool) { $('.fbb-help-text').slideUp(150); _fbbF1Open_bool = false; } else { $('.fbb-help-text').each(function () { const $guard = $(this).data('fbb-guard'); if ($guard && !$guard.is(':visible')) return; $(this).slideDown(150); }); _fbbF1Open_bool = true; } });
  $(document).on('click', function () { if (Date.now() - _fbbLastClick_int < 150) return; $('.fbb-help-text').slideUp(150); _fbbF1Open_bool = false; });

  function vmbrInitTooltipster($el_arr) { $el_arr.each(function () { const $el = $(this); if ($el.hasClass('tooltipstered')) return; const tip_str = $el.attr('title') || ''; if (!tip_str) return; $el.tooltipster({ maxWidth: 300, content: tip_str }); $el.removeAttr('title'); }); }
  vmbrInitTooltipster($('#vmbr-schedule-btn, #vmbr-schedule-update-btn, #vmbr-schedule-cancel-edit-btn, #vmbr-backup-save-btn, #vmbr-restore-save-btn, #vmbr-backup-stop-btn, #vmbr-restore-stop-btn, #vmbr-backup-now-btn, #vmbr-restore-now-btn, #vmbr-log-clear-btn, #vmbr-log-copy-btn, #vmbr-log-scroll-top-btn, #vmbr-log-autoscroll-btn'));

  $(document).on('mouseenter', 'table button[title], table [title]', function () { const $el = $(this); if ($el.hasClass('tooltipstered')) return; const tip_str = $el.attr('title') || ''; if (!tip_str) return; $el.tooltipster({ maxWidth: 300, content: tip_str }); $el.removeAttr('title'); setTimeout(() => { if ($el.is(':hover')) $el.tooltipster('open'); }, 200); });
});
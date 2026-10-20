// Used in Plugin Settings page to delete transition
function deleteTransitionField(from_id) {
  // changes field name to remove from settings.
  document.getElementById('settings_status_transitions_' + from_id).name = "deleted_transition" + from_id;
}

// Used in Plugin Settings page to add transition
function addTransitionField() {
  // inserts new hidden tag for new status transition.
  var elem = document.getElementById('add-transition');
  var to_id = document.getElementById('new-transition-to').value;
  var from_id = document.getElementById('new-transition-from').value;
  var new_tag = '<input type="hidden" id="settings_status_transition_' + from_id + '" name="settings[status_transitions][' + from_id + ']" value="' + to_id + '">';
  elem.innerHTML = new_tag;
}

// timer
let x;
let started_on = 0;
let elapsed_seconds = 0;

function pause_timer() {
  if (!x) { return; } // no timer running
  stop_timer();
}

function start_timer(sec, min, hour) {
  stop_timer();
  elapsed_seconds = Number(sec) + Number(min) * 60 + Number(hour) * 3600;
  started_on = Date.now();
  tl_timer();
  x = setInterval(tl_timer, 1000);
}

function stop_timer() {
  clearInterval(x);
  x = null;
}

// Output variable End
function tl_timer() {
  const total = elapsed_seconds + Math.max(0, Math.floor((Date.now() - started_on) / 1000));
  const values = { hour: Math.floor(total / 3600), min: Math.floor(total / 60) % 60, sec: total % 60 };
  Object.entries(values).forEach(function ([identifier, value]) {
    const element = document.getElementById(identifier);
    if (element) { element.textContent = checkTime(value); }
  });
}

// Adds 0 when value is <10
function checkTime(i) {
  if (i < 10) {
    i = "0" + i;
  }
  return i;
}
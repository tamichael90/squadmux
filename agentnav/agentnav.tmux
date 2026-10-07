# agentnav: clickable sidebar of Claude Code agent panes plus a CONTEXT file tree (see agentnav.sh)
# Clicking the CONTEXT panel focuses it; a sidebar click focuses the chosen agent (no-op clicks leave focus
# alone). Arrow keys are handled by the panel processes, not bound here.
bind -n MouseDown1Pane if -F -t = '#{==:#{@agentnav_role},sidebar}' {
  run-shell -b -t = "~/.config/agentnav/agentnav.sh click #{mouse_y} #{pane_id}"
} {
  if -F -t = '#{==:#{@agentnav_role},context}' {
    select-pane -t = ; run-shell -b -t = "~/.config/agentnav/agentnav.sh ctxclick #{mouse_y} #{pane_id} #{client_name}"
  } {
    select-pane -t = ; send-keys -M
  }
}
bind -n WheelUpPane if -F -t = '#{==:#{@agentnav_role},context}' {
  run-shell -b -t = "~/.config/agentnav/agentnav.sh ctxscroll -3 #{pane_id}"
} {
  if -F -t = '#{||:#{pane_in_mode},#{mouse_any_flag}}' 'send-keys -M' 'copy-mode -e'
}
bind -n WheelDownPane if -F -t = '#{==:#{@agentnav_role},context}' {
  run-shell -b -t = "~/.config/agentnav/agentnav.sh ctxscroll +3 #{pane_id}"
} {
  select-pane -t = ; send-keys -M
}
set-hook -g after-split-window 'run-shell -b "~/.config/agentnav/agentnav.sh auto #{pane_id}"'

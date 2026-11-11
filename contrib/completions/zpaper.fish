# fish completions for zpaper.
# Install: cp contrib/completions/zpaper.fish ~/.config/fish/completions/

# Run zpaper with any --config from the command line being completed, so
# collections and outputs come from the same configuration. A short timeout
# keeps a busy renderer from stalling the prompt.
function __zpaper_query
    set -l tokens (commandline -opc)
    set -l args
    set -l index (contains -i -- --config $tokens)
    and set -q tokens[(math $index + 1)]
    and set args --config $tokens[(math $index + 1)]
    if command -q timeout
        timeout 3 zpaper $args $argv 2>/dev/null
    else
        zpaper $args $argv 2>/dev/null
    end
end

function __zpaper_collections
    __zpaper_query collections --json | string match -rag '"name":"((?:[^"\\\\]|\\\\.)*)"'
end

# Connected outputs from the renderer (awww/swww). Global backends report "*",
# which is not a valid --output value.
function __zpaper_outputs
    __zpaper_query current --json | string match -rag '"output":"((?:[^"\\\\]|\\\\.)*)"' | path sort -u | string match -rv '^\*$'
end

set -l commands daemon set next previous hold resume current status history layouts search select favorite unfavorite favorites random-favorite exclude include collections use schedule list restore refresh import-legacy clear-history reload stop check
set -l json_commands current status history layouts favorites list collections schedule
set -l output_commands set next hold resume select favorite unfavorite exclude include random-favorite
set -l image_commands set favorite unfavorite exclude include

complete -c zpaper -f

# Global options
complete -c zpaper -s h -l help -d 'Show help'
complete -c zpaper -l version -d 'Show version'
complete -c zpaper -l config -r -F -d 'Configuration file'

# Commands
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a daemon -d 'Run in the foreground'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a set -d 'Set image(s), one per output'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a next -d 'Next layout, or a new image'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a previous -d 'Previous layout'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a hold -d 'Pause automatic rotation'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a resume -d 'Release holds'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a current -d 'Query the renderer'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a status -d 'Show recorded state'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a history -d 'Image history'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a layouts -d 'Layout timeline'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a search -d 'Search image history'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a select -d 'Apply history entry N'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a favorite -d 'Favorite current or given images'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a unfavorite -d 'Remove favorites'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a favorites -d 'List favorites'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a random-favorite -d 'Apply a random favorite'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a exclude -d 'Exclude images from rotation'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a include -d 'Include excluded images again'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a collections -d 'List collections'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a use -d 'Switch the active collection'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a schedule -d 'Show or resume the schedule'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a list -d 'List images in a collection'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a restore -d 'Reapply the saved layout'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a refresh -d 'Reapply the saved layout'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a import-legacy -d 'Import old script history'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a clear-history -d 'Clear history and layouts'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a reload -d 'Reload the daemon config'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a stop -d 'Stop the daemon'
complete -c zpaper -n "not __fish_seen_subcommand_from $commands" -a check -d 'Validate the configuration'

# Command arguments
complete -c zpaper -n "__fish_seen_subcommand_from $image_commands" -F
complete -c zpaper -n "__fish_seen_subcommand_from use list" -a '(__zpaper_collections)' -d Collection
complete -c zpaper -n "__fish_seen_subcommand_from schedule" -a resume -d 'Follow the schedule again'
complete -c zpaper -n "__fish_seen_subcommand_from hold" -a '15m 30m 1h 2h 8h 1d' -d Duration
complete -c zpaper -n "__fish_seen_subcommand_from import-legacy" -a '(__fish_complete_directories)'

# Command options
complete -c zpaper -n "__fish_seen_subcommand_from $json_commands" -l json -d 'JSON output'
complete -c zpaper -n "__fish_seen_subcommand_from $output_commands" -s o -l output -x -a '(__zpaper_outputs)' -d 'Output(s), comma-separated'

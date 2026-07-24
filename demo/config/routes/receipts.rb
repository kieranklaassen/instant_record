# What this runtime actually cost, measured on this device rather than quoted.
get "receipts", to: "receipts#index", as: :receipts

# The timed probe the page runs twice: once against whatever runtime serves this
# page, and once against the real server, so local and networked are the same
# request measured at the same moment.
get "receipts/probe", to: "receipts#probe", as: :receipts_probe

# samples

Drop real photos of your own cards here and run `swift run riftscan evaluate samples`.

Name each file by the card it shows so it can be scored automatically:

- the catalog id, e.g. `ogn-001-298.jpg`, `ogn-007a-298 kitchen-table.heic`
- or the printed code with the slash written as a hyphen, e.g. `OGN-001-298.jpg`

Anything after the first space, underscore or `(` is ignored. Files whose names
do not resolve to a card are skipped. Nothing in this folder is downloaded; it
only ever holds photos you took yourself.

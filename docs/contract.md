# chopshop-studio — Interface Contract

Metrics engine configuration + presentation of server statistics. Calls `chopshop-bp`
for blend-plot work; never scores/ranks itself.

## Rails routes (`config/routes.rb`)

| Route | Action | Purpose |
|---|---|---|
| root      | projects#index | project list |
| get login / post login | application#login/authenticate | auth |
| get json / post json/use | pages#schema / apply_spec | JSON spec |
| post templates/use | pages#apply_template | templates |
| get jev | pages#jev | jev panel |
| get flux | pages#flux | flux panel |
| get bp | pages#bp | blend-plot panel |
| get plot | pages#plot | plot panel |
| get blender | pages#blender | 3D render |
| get status | pages#status | server status |

## Deploy invariant

Live app runs Puma under `chopshop-rails.service` (systemd USER unit). After ANY
`app/` or `config/` change or `git pull`: `systemctl --user restart chopshop-rails.service`
and verify the served page BEFORE reporting done. Unit of done = live page, not edited file.

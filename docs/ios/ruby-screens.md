# Ruby screens

A screen is one Ruby class in `app/screens`. It runs on the phone, reads your models from the phone's SQLite, and is drawn with stock iOS controls.

```ruby
# app/screens/catalog_screen.rb
class CatalogScreen < InstantRecord::Native::Screen
  def body
    navigation title: "Catalog" do
      list refreshable: true do
        Product.order(:name).each do |product|
          row id: product.id, link: "product", params: { "id" => product.id.to_s } do
            text product.name, style: "headline"
            text product.summary, tone: "secondary", lines: 2
            swipe "Save", action: "save", args: { "id" => product.id.to_s }
          end
        end
      end
    end
  end

  def perform(action, args, values)
    case action
    when "save" then Product.find(args.fetch("id", "")).update!(saved: true)
    end
  end
end
```

`body` describes the screen. `perform` answers taps. The write is local and syncs afterwards, so it works offline.

## Elements

| Method | Draws |
|---|---|
| `navigation title:` | the bar and its title |
| `list`, `section`, `row` | a list, its sections, its rows |
| `stack`, `spacer` | things side by side or one under another |
| `text`, `date`, `image` | words, a moment, an icon |
| `button`, `item`, `swipe` | a button, a menu's line, a row's swipe action |
| `toolbar`, `bottom`, `field` | bar buttons, a pinned bar, a text box |
| `more` | the next page of a long list |
| `toggle`, `slider`, `stepper`, `picker`, `date_picker`, `color_picker` | controls |
| `progress`, `gauge`, `labeled`, `divider` | how far, how full, words with an icon, a line |
| `picture`, `video`, `model_3d`, `share_link` | media by URL: an image, a film, a USDZ, a share button |
| `chart` with `point`, `map_view` with `pin` | a chart, a map |
| `scroll`, `grid`, `card`, `pages`, `disclosure` | arrangements outside a list |
| `swift` | one of your [SwiftUI views](swiftui-views.md) |
| `web` | one of your [Rails pages](rails-pages.md), in the room that is left: beside a list, not in one |

A control keeps its value by `name` until the next action, and `perform` reads it in `values`. With an `action` it is performed at once. Amounts are strings:

```ruby
slider "volume", value: "0.5", min: "0", max: "1", action: "set_volume"
picker "sort", value: "new", style: "segmented" do
  option "Newest", "new"
  option "Oldest", "old"
end
chart style: "line" do
  days.each { |day| point day.name, day.total.to_s }
end
```

## Where a link goes

`link:` on a row, and `link:` and `sheet:` on a menu item, take an address of any of the three kinds:

```ruby
row link: "product", params: { "id" => product.id.to_s }   # a Ruby screen
row link: "swift:MapView", params: { "at" => shop.place }  # a SwiftUI view
row link: "page:/orders/#{order.id}"                       # a Rails page
```

## Testing

A screen is plain Ruby, so a test needs no simulator:

```ruby
tree = JSON.parse(CatalogScreen.new.json)
```

## Keep to plain Ruby

The phone's compiler has no `method_missing`, `instance_eval` or `send` to a computed name. `params:` and `args:` hold strings only, so write `product.id.to_s`.

# ZoneMap
this repo draws the zones and subzones on your map in classic wow! click the button in the top right of the map to enable. an asterisk next to the area-id means this zone gives xp.

## Contributing
### ADT Files
In WoWs game files there exists `.adt` files. These contain zone and subzone information for every portion of the map. I had a hard time parsing the game files from classic wow version 1.15x because the archiving method uses `CASC`, and `CASC` was too convoluted. Private servers use an older archiving method that is easier to parse, and using that gave us the `.adt` files we needed

### Generated Files
Data/Azeroth_tiles.lua and Data/Kalimdor_tiles.lua
    - a dictionary where the key is the grid index of the adt block/tile and the value is all of the areaIds in that adt block/tile

Data/AreaInfo.lua
    - a dictionary where the key is the areaId and the values are useful info like what color to draw, if it gives exploration xp, and its parent zone/area

Data/AreaHierarchy.lua
    - a dictionary where the key is the root area zone and the values are all the zones/areas that are children to it

Data/MapToArea.lua
    - a dictionary of mapIds to its root areaId

To generate the files:
```
cargo run
```


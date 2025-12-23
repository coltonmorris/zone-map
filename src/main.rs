use wow_adt::Adt;

use base64::{engine::general_purpose, Engine as _};

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Cursor, Write};
use std::path::{Path, PathBuf};

// ============================================================================
// Area Table parsing
// ============================================================================

#[derive(Debug, Clone)]
struct AreaInfo {
    id: u32,
    name: String,
    parent_id: u32,
    exploration_level: i32,
}

fn parse_area_table(csv_path: &Path) -> Result<HashMap<u32, AreaInfo>, Box<dyn std::error::Error>> {
    let file = File::open(csv_path)?;
    let reader = BufReader::new(file);
    let mut areas = HashMap::new();
    
    let mut lines = reader.lines();
    let header = lines.next().ok_or("Empty CSV")??;
    
    let columns: Vec<&str> = header.split(',').collect();
    let id_idx = columns.iter().position(|&c| c == "ID").ok_or("No ID column")?;
    let name_idx = columns.iter().position(|&c| c == "AreaName_lang").ok_or("No AreaName_lang column")?;
    let parent_idx = columns.iter().position(|&c| c == "ParentAreaID").ok_or("No ParentAreaID column")?;
    let level_idx = columns.iter().position(|&c| c == "ExplorationLevel").ok_or("No ExplorationLevel column")?;
    
    for line in lines {
        let line = line?;
        let fields: Vec<&str> = parse_csv_line(&line);
        
        if fields.len() <= id_idx.max(name_idx).max(parent_idx).max(level_idx) {
            continue;
        }
        
        let id: u32 = match fields[id_idx].parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        
        let name = fields[name_idx].trim_matches('"').to_string();
        let parent_id: u32 = fields[parent_idx].parse().unwrap_or(0);
        let exploration_level: i32 = fields[level_idx].parse().unwrap_or(0);
        
        areas.insert(id, AreaInfo { id, name, parent_id, exploration_level });
    }
    
    Ok(areas)
}

fn parse_csv_line(line: &str) -> Vec<&str> {
    let mut fields = Vec::new();
    let mut start = 0;
    let mut in_quotes = false;
    let bytes = line.as_bytes();
    
    for i in 0..bytes.len() {
        match bytes[i] {
            b'"' => in_quotes = !in_quotes,
            b',' if !in_quotes => {
                fields.push(&line[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    fields.push(&line[start..]);
    fields
}

fn find_root_parent(area_id: u32, areas: &HashMap<u32, AreaInfo>) -> u32 {
    let mut current = area_id;
    let mut visited = BTreeSet::new();
    
    while let Some(area) = areas.get(&current) {
        if area.parent_id == 0 || visited.contains(&current) {
            return current;
        }
        visited.insert(current);
        current = area.parent_id;
    }
    area_id
}

// ============================================================================
// Map ID to Area ID mapping
// ============================================================================

#[derive(Debug)]
struct MapToAreaEntry {
    zone_name: String,
    map_id: u32,
    area_id: u32,
}

fn parse_map_to_area_csv(csv_path: &Path) -> Result<Vec<MapToAreaEntry>, Box<dyn std::error::Error>> {
    let file = File::open(csv_path)?;
    let reader = BufReader::new(file);
    let mut entries = Vec::new();
    
    let mut lines = reader.lines();
    let header = lines.next().ok_or("Empty CSV")??;
    
    // Parse header to find column indices
    let columns: Vec<&str> = header.split(',').collect();
    let zone_idx = columns.iter().position(|&c| c.trim() == "Zone").ok_or("No Zone column")?;
    let map_id_idx = columns.iter().position(|&c| c.trim() == "mapId").ok_or("No mapId column")?;
    let area_id_idx = columns.iter().position(|&c| c.trim() == "AreaId").ok_or("No AreaId column")?;
    
    for line in lines {
        let line = line?;
        let fields: Vec<&str> = parse_csv_line(&line);
        
        if fields.len() <= zone_idx.max(map_id_idx).max(area_id_idx) {
            continue;
        }
        
        let zone_name = fields[zone_idx].trim_matches('"').to_string();
        let map_id: u32 = match fields[map_id_idx].trim().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        let area_id: u32 = match fields[area_id_idx].trim().parse() {
            Ok(v) => v,
            Err(_) => continue,
        };
        
        entries.push(MapToAreaEntry { zone_name, map_id, area_id });
    }
    
    Ok(entries)
}

fn export_map_to_area(entries: &[MapToAreaEntry], out_path: &Path) -> std::io::Result<()> {
    let mut f = File::create(out_path)?;
    
    writeln!(f, "-- Auto-generated Map ID to Area ID mapping")?;
    writeln!(f, "-- Maps WoW UI map IDs to parent area IDs")?;
    writeln!(f)?;
    writeln!(f, "local _, addon = ...")?;
    writeln!(f)?;
    writeln!(f, "addon.MapToArea = {{")?;
    
    for entry in entries {
        let escaped_name = entry.zone_name.replace("\"", "\\\"");
        writeln!(f, "  [{}] = {{ areaId = {}, name = \"{}\" }},", 
            entry.map_id, entry.area_id, escaped_name)?;
    }
    
    writeln!(f, "}}")?;
    
    // Also create reverse lookup (areaId -> mapId)
    writeln!(f)?;
    writeln!(f, "addon.AreaToMap = {{")?;
    
    for entry in entries {
        writeln!(f, "  [{}] = {},", entry.area_id, entry.map_id)?;
    }
    
    writeln!(f, "}}")?;
    
    Ok(())
}

// ============================================================================
// Neighbor detection and graph coloring
// ============================================================================

type NeighborGraph = HashMap<u32, HashSet<u32>>;

/// Add a neighbor relationship (bidirectional)
fn add_neighbor(graph: &mut NeighborGraph, a: u32, b: u32) {
    if a != 0 && b != 0 && a != b {
        graph.entry(a).or_default().insert(b);
        graph.entry(b).or_default().insert(a);
    }
}

/// Find neighbors within a single tile (adjacent chunks with different area IDs)
fn find_tile_neighbors(area_ids: &[u32], graph: &mut NeighborGraph) {
    // area_ids is 256 elements, 16x16 grid
    // Check horizontal neighbors (left-right)
    for y in 0..16 {
        for x in 0..15 {
            let idx1 = y * 16 + x;
            let idx2 = y * 16 + x + 1;
            add_neighbor(graph, area_ids[idx1], area_ids[idx2]);
        }
    }
    
    // Check vertical neighbors (up-down)
    for y in 0..15 {
        for x in 0..16 {
            let idx1 = y * 16 + x;
            let idx2 = (y + 1) * 16 + x;
            add_neighbor(graph, area_ids[idx1], area_ids[idx2]);
        }
    }
}

/// Find neighbors between adjacent tiles
fn find_inter_tile_neighbors(
    tiles: &HashMap<u32, Vec<u32>>,
    graph: &mut NeighborGraph,
) {
    for (&key, area_ids) in tiles {
        let tile_x = key % 64;
        let tile_y = key / 64;
        
        // Check right neighbor tile
        if tile_x < 63 {
            let right_key = tile_y * 64 + tile_x + 1;
            if let Some(right_ids) = tiles.get(&right_key) {
                // Compare rightmost column of current tile with leftmost column of right tile
                for y in 0..16 {
                    let idx_current = y * 16 + 15;  // Rightmost column
                    let idx_right = y * 16 + 0;     // Leftmost column
                    add_neighbor(graph, area_ids[idx_current], right_ids[idx_right]);
                }
            }
        }
        
        // Check bottom neighbor tile
        if tile_y < 63 {
            let bottom_key = (tile_y + 1) * 64 + tile_x;
            if let Some(bottom_ids) = tiles.get(&bottom_key) {
                // Compare bottom row of current tile with top row of bottom tile
                for x in 0..16 {
                    let idx_current = 15 * 16 + x;  // Bottom row
                    let idx_bottom = 0 * 16 + x;    // Top row
                    add_neighbor(graph, area_ids[idx_current], bottom_ids[idx_bottom]);
                }
            }
        }
    }
}

/// Generate distinct colors using graph coloring
/// Returns a map of area_id -> (r, g, b)
fn generate_colors_with_graph(
    found_areas: &BTreeSet<u32>,
    neighbors: &NeighborGraph,
    areas: &HashMap<u32, AreaInfo>,
) -> HashMap<u32, (f32, f32, f32)> {
    let mut colors: HashMap<u32, (f32, f32, f32)> = HashMap::new();
    
    // Predefined palette of visually distinct colors
    let palette: Vec<(f32, f32, f32)> = vec![
        (0.90, 0.30, 0.30),  // Red
        (0.30, 0.70, 0.30),  // Green
        (0.30, 0.50, 0.90),  // Blue
        (0.90, 0.80, 0.20),  // Yellow
        (0.80, 0.40, 0.80),  // Purple
        (0.20, 0.80, 0.80),  // Cyan
        (0.95, 0.60, 0.30),  // Orange
        (0.60, 0.80, 0.40),  // Lime
        (0.80, 0.50, 0.60),  // Pink
        (0.50, 0.70, 0.80),  // Sky blue
        (0.70, 0.60, 0.40),  // Tan
        (0.60, 0.40, 0.70),  // Violet
        (0.40, 0.60, 0.50),  // Teal
        (0.85, 0.70, 0.70),  // Light pink
        (0.70, 0.85, 0.70),  // Light green
        (0.70, 0.70, 0.85),  // Light blue
    ];
    
    // Sort areas by number of neighbors (descending) for better coloring
    let mut area_list: Vec<u32> = found_areas.iter().copied().filter(|&a| a != 0).collect();
    area_list.sort_by_key(|&a| std::cmp::Reverse(neighbors.get(&a).map(|n| n.len()).unwrap_or(0)));
    
    for area_id in area_list {
        // Find colors used by neighbors
        let neighbor_colors: HashSet<usize> = neighbors
            .get(&area_id)
            .map(|ns| {
                ns.iter()
                    .filter_map(|&n| {
                        colors.get(&n).and_then(|c| {
                            palette.iter().position(|p| {
                                (p.0 - c.0).abs() < 0.01 && 
                                (p.1 - c.1).abs() < 0.01 && 
                                (p.2 - c.2).abs() < 0.01
                            })
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        
        // Also avoid parent color
        let parent_id = areas.get(&area_id).map(|a| a.parent_id).unwrap_or(0);
        let parent_color_idx: Option<usize> = colors.get(&parent_id).and_then(|c| {
            palette.iter().position(|p| {
                (p.0 - c.0).abs() < 0.01 && 
                (p.1 - c.1).abs() < 0.01 && 
                (p.2 - c.2).abs() < 0.01
            })
        });
        
        // Find first available color
        let mut chosen_idx = 0;
        for i in 0..palette.len() {
            if !neighbor_colors.contains(&i) && parent_color_idx != Some(i) {
                chosen_idx = i;
                break;
            }
        }
        
        // If all colors used, generate a unique one based on area_id
        let color = if chosen_idx < palette.len() && !neighbor_colors.contains(&chosen_idx) {
            palette[chosen_idx]
        } else {
            // Fallback: generate unique color
            let golden_ratio = 0.618033988749895_f64;
            let hue = ((area_id as f64) * golden_ratio) % 1.0;
            let s = 0.7_f64;
            let v = 0.9_f64;
            let c = v * s;
            let x = c * (1.0 - ((hue * 6.0) % 2.0 - 1.0).abs());
            let m = v - c;
            
            let (r, g, b) = match (hue * 6.0) as i32 {
                0 => (c, x, 0.0),
                1 => (x, c, 0.0),
                2 => (0.0, c, x),
                3 => (0.0, x, c),
                4 => (x, 0.0, c),
                _ => (c, 0.0, x),
            };
            ((r + m) as f32, (g + m) as f32, (b + m) as f32)
        };
        
        colors.insert(area_id, color);
    }
    
    colors
}

/// Export area info to Lua
fn export_area_info(
    found_areas: &BTreeSet<u32>,
    areas: &HashMap<u32, AreaInfo>,
    colors: &HashMap<u32, (f32, f32, f32)>,
    neighbors: &NeighborGraph,
    out_path: &Path,
) -> std::io::Result<()> {
    let mut f = File::create(out_path)?;
    
    writeln!(f, "-- Auto-generated Area Info")?;
    writeln!(f, "-- Contains name, parent, level, color, and neighbors for each area")?;
    writeln!(f)?;
    writeln!(f, "local _, addon = ...")?;
    writeln!(f)?;
    writeln!(f, "addon.AreaInfo = {{")?;
    
    for &area_id in found_areas {
        if area_id == 0 {
            continue;
        }
        
        let (name, parent_id, root_parent, level) = if let Some(area) = areas.get(&area_id) {
            let root = find_root_parent(area_id, areas);
            (area.name.clone(), area.parent_id, root, area.exploration_level)
        } else {
            (format!("Unknown_{}", area_id), 0, area_id, 0)
        };
        
        let (r, g, b) = colors.get(&area_id).copied().unwrap_or((0.5, 0.5, 0.5));
        let escaped_name = name.replace("\"", "\\\"");
        
        // Get neighbor count for info
        let neighbor_count = neighbors.get(&area_id).map(|n| n.len()).unwrap_or(0);
        
        writeln!(f, "  [{}] = {{", area_id)?;
        writeln!(f, "    name = \"{}\",", escaped_name)?;
        writeln!(f, "    parentId = {},", parent_id)?;
        writeln!(f, "    rootParentId = {},", root_parent)?;
        writeln!(f, "    explorationLevel = {},", level)?;
        writeln!(f, "    color = {{{:.3}, {:.3}, {:.3}}},", r, g, b)?;
        writeln!(f, "    neighborCount = {},", neighbor_count)?;
        writeln!(f, "  }},")?;
    }
    
    writeln!(f, "}}")?;
    Ok(())
}

fn export_area_hierarchy(
    found_areas: &BTreeSet<u32>,
    areas: &HashMap<u32, AreaInfo>,
    out_path: &Path,
) -> std::io::Result<()> {
    // Group areas by root parent
    let mut hierarchy: BTreeMap<u32, BTreeMap<u32, String>> = BTreeMap::new();
    
    for &area_id in found_areas {
        if area_id == 0 {
            continue;
        }
        
        let root_parent = find_root_parent(area_id, areas);
        let name = if let Some(area) = areas.get(&area_id) {
            area.name.clone()
        } else {
            format!("Unknown_{}", area_id)
        };
        
        hierarchy
            .entry(root_parent)
            .or_insert_with(BTreeMap::new)
            .insert(area_id, name);
    }
    
    let mut f = File::create(out_path)?;
    
    writeln!(f, "-- Auto-generated Area Hierarchy")?;
    writeln!(f, "-- Groups areas by their root parent zone")?;
    writeln!(f)?;
    writeln!(f, "local _, addon = ...")?;
    writeln!(f)?;
    writeln!(f, "addon.AreaHierarchy = {{")?;
    
    for (root_id, children) in &hierarchy {
        let root_name = if let Some(area) = areas.get(root_id) {
            area.name.replace("\"", "\\\"")
        } else {
            format!("Unknown_{}", root_id)
        };
        
        writeln!(f, "  [{}] = {{  -- {}", root_id, root_name)?;
        writeln!(f, "    name = \"{}\",", root_name)?;
        writeln!(f, "    children = {{")?;
        
        for (child_id, child_name) in children {
            let escaped = child_name.replace("\"", "\\\"");
            writeln!(f, "      [{}] = \"{}\",", child_id, escaped)?;
        }
        
        writeln!(f, "    }},")?;
        writeln!(f, "  }},")?;
    }
    
    writeln!(f, "}}")?;
    
    println!("  {} root zones, {} total areas", hierarchy.len(), found_areas.len());
    Ok(())
}

// ============================================================================
// ADT / Tile parsing
// ============================================================================

fn parse_root_adt_filename(path: &Path) -> Option<(String, u32, u32)> {
    if path.extension()?.to_str()?.to_ascii_lowercase() != "adt" {
        return None;
    }
    let stem = path.file_stem()?.to_str()?.to_string();
    let parts: Vec<&str> = stem.split('_').collect();
    if parts.len() != 3 {
        return None;
    }
    let map = parts[0].to_string();
    let x: u32 = parts[1].parse().ok()?;
    let y: u32 = parts[2].parse().ok()?;
    Some((map, x, y))
}

fn tile_key(tile_x: u32, tile_y: u32) -> u32 {
    tile_y * 64 + tile_x
}

fn encode_tile_b64(area_ids_256: &[u32]) -> Result<String, Box<dyn std::error::Error>> {
    if area_ids_256.len() != 256 {
        return Err(format!("expected 256 area IDs, got {}", area_ids_256.len()).into());
    }

    let mut raw = Vec::with_capacity(256 * 4);
    for &v in area_ids_256 {
        raw.extend_from_slice(&v.to_le_bytes());
    }

    Ok(general_purpose::STANDARD.encode(&raw))
}

fn parse_adt_areaids(path: &Path) -> Result<Option<Vec<u32>>, Box<dyn std::error::Error>> {
    let data = fs::read(path)?;
    let adt = Adt::from_reader(Cursor::new(data))?;

    let mut area_ids: Vec<u32> = adt
        .mcnk_chunks
        .iter()
        .map(|chunk| chunk.area_id)
        .collect();

    if area_ids.is_empty() {
        return Ok(None);
    }
    
    if area_ids.len() != 256 {
        area_ids.resize(256, 0);
    }

    Ok(Some(area_ids))
}

struct TileGridExport {
    continent_name: String,
    tiles_b64: BTreeMap<u32, String>,
    tiles_raw: HashMap<u32, Vec<u32>>,
    found_areas: BTreeSet<u32>,
}

impl TileGridExport {
    fn new(continent_name: &str) -> Self {
        Self {
            continent_name: continent_name.to_string(),
            tiles_b64: BTreeMap::new(),
            tiles_raw: HashMap::new(),
            found_areas: BTreeSet::new(),
        }
    }

    fn export_lua(&self, out_path: &Path) -> std::io::Result<()> {
        let mut f = File::create(out_path)?;

        writeln!(f, "-- Auto-generated AreaID grid for {}", self.continent_name)?;
        writeln!(f, "-- Each tile is 16x16 chunks (256 u32 AreaIDs), base64 encoded.")?;
        writeln!(f)?;
        writeln!(f, "local _, addon = ...")?;
        writeln!(f)?;
        writeln!(f, "local tiles = {{")?;

        for (k, v) in &self.tiles_b64 {
            writeln!(f, "  [{}] = [[{}]],", k, v)?;
        }

        writeln!(f, "}}")?;
        writeln!(f)?;
        writeln!(f, "addon:RegisterTileGrid(\"{}\", {{", self.continent_name)?;
        writeln!(f, "  name = \"{}\",", self.continent_name)?;
        writeln!(f, "  tileSize = 16,")?;
        writeln!(f, "  tilesPerSide = 64,")?;
        writeln!(f, "  tiles = tiles,")?;
        writeln!(f, "}})")?;
        Ok(())
    }
}

fn build_tile_export(adt_dir: &Path, continent_name: &str) -> Result<TileGridExport, Box<dyn std::error::Error>> {
    let mut export = TileGridExport::new(continent_name);

    if !adt_dir.exists() {
        return Err(format!("Directory not found: {}", adt_dir.display()).into());
    }

    println!("Scanning: {}", adt_dir.display());

    let mut parsed = 0usize;

    for entry in fs::read_dir(adt_dir)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let Some((_, tx, ty)) = parse_root_adt_filename(&path) else {
            continue;
        };

        match parse_adt_areaids(&path) {
            Ok(Some(area_ids)) => {
                for &aid in &area_ids {
                    if aid != 0 {
                        export.found_areas.insert(aid);
                    }
                }
                
                let b64 = encode_tile_b64(&area_ids)?;
                let key = tile_key(tx, ty);
                export.tiles_b64.insert(key, b64);
                export.tiles_raw.insert(key, area_ids);
                parsed += 1;
            }
            Ok(None) => {}
            Err(e) => {
                eprintln!("  ERROR parsing {}: {}", path.display(), e);
            }
        }
    }

    println!("  Parsed {} tiles, found {} unique areas", parsed, export.found_areas.len());
    Ok(export)
}

fn main() {
    println!("ZoneMap Tile Generator\n");
    
    // Load area table
    let csv_path = Path::new("AreaTable.1.15.8.64907.csv");
    let areas = if csv_path.exists() {
        match parse_area_table(csv_path) {
            Ok(a) => {
                println!("Loaded {} areas from CSV\n", a.len());
                a
            }
            Err(e) => {
                eprintln!("Warning: Failed to parse area table: {}", e);
                HashMap::new()
            }
        }
    } else {
        eprintln!("Warning: AreaTable CSV not found\n");
        HashMap::new()
    };
    
    // Create Data directory
    let out_dir = Path::new("Data");
    if !out_dir.exists() {
        if let Err(e) = fs::create_dir(out_dir) {
            eprintln!("Failed to create Data directory: {}", e);
            return;
        }
        println!("Created Data/ directory");
    }
    
    // Track all data across continents
    let mut all_found_areas = BTreeSet::new();
    let mut all_tiles_raw: HashMap<u32, Vec<u32>> = HashMap::new();
    let mut neighbor_graph: NeighborGraph = HashMap::new();
    
    // Process Kalimdor
    if let Ok(export) = build_tile_export(Path::new("kalimdor_adts"), "Kalimdor") {
        all_found_areas.extend(&export.found_areas);
        
        // Find neighbors within tiles
        for area_ids in export.tiles_raw.values() {
            find_tile_neighbors(area_ids, &mut neighbor_graph);
        }
        
        // Find neighbors between tiles
        find_inter_tile_neighbors(&export.tiles_raw, &mut neighbor_graph);
        
        // Export before moving tiles_raw
        let out_path = out_dir.join("Kalimdor_tiles.lua");
        if let Err(e) = export.export_lua(&out_path) {
            eprintln!("Failed to write: {}", e);
        } else {
            println!("  Wrote: {}", out_path.display());
        }
        
        all_tiles_raw.extend(export.tiles_raw);
    }
    
    // Process Azeroth
    if let Ok(export) = build_tile_export(Path::new("azeroth_adts"), "Azeroth") {
        all_found_areas.extend(&export.found_areas);
        
        for area_ids in export.tiles_raw.values() {
            find_tile_neighbors(area_ids, &mut neighbor_graph);
        }
        find_inter_tile_neighbors(&export.tiles_raw, &mut neighbor_graph);
        
        // Export before moving tiles_raw
        let out_path = out_dir.join("Azeroth_tiles.lua");
        if let Err(e) = export.export_lua(&out_path) {
            eprintln!("Failed to write: {}", e);
        } else {
            println!("  Wrote: {}", out_path.display());
        }
        
        all_tiles_raw.extend(export.tiles_raw);
    }
    
    // Generate colors using neighbor graph
    println!("\nBuilding neighbor graph...");
    println!("  Found {} areas with neighbor relationships", neighbor_graph.len());
    
    let colors = generate_colors_with_graph(&all_found_areas, &neighbor_graph, &areas);
    
    // Export area info with graph-colored colors
    println!("\nGenerating area info...");
    let area_info_path = out_dir.join("AreaInfo.lua");
    if let Err(e) = export_area_info(&all_found_areas, &areas, &colors, &neighbor_graph, &area_info_path) {
        eprintln!("Failed to write area info: {}", e);
    } else {
        println!("  Wrote: {}", area_info_path.display());
    }
    
    // Export area hierarchy grouped by root parent
    println!("\nGenerating area hierarchy...");
    let hierarchy_path = out_dir.join("AreaHierarchy.lua");
    if let Err(e) = export_area_hierarchy(&all_found_areas, &areas, &hierarchy_path) {
        eprintln!("Failed to write area hierarchy: {}", e);
    } else {
        println!("  Wrote: {}", hierarchy_path.display());
    }
    
    // Export map ID to area ID mapping
    let map_csv_path = Path::new("mapIdToArea.csv");
    if map_csv_path.exists() {
        println!("\nGenerating map to area mapping...");
        match parse_map_to_area_csv(map_csv_path) {
            Ok(entries) => {
                println!("  Loaded {} map-to-area entries", entries.len());
                let map_path = out_dir.join("MapToArea.lua");
                if let Err(e) = export_map_to_area(&entries, &map_path) {
                    eprintln!("Failed to write map to area: {}", e);
                } else {
                    println!("  Wrote: {}", map_path.display());
                }
            }
            Err(e) => {
                eprintln!("Failed to parse mapIdToArea.csv: {}", e);
            }
        }
    } else {
        println!("\nSkipping map-to-area (mapIdToArea.csv not found)");
    }
    
    println!("\nDone!");
}

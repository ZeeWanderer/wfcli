pub(crate) struct EmbeddedImage {
    pub key: &'static str,
    pub bytes: &'static [u8],
}

pub(crate) struct EmbeddedAsset {
    pub id: &'static str,
    pub image: &'static EmbeddedImage,
}

macro_rules! image {
    ($name:ident, $path:literal) => {
        const $name: EmbeddedImage = EmbeddedImage {
            key: $path,
            bytes: include_bytes!(concat!("../assets/relic-parts/", $path)),
        };
    };
}

macro_rules! asset {
    ($id:literal, $image:ident) => {
        EmbeddedAsset {
            id: $id,
            image: &$image,
        }
    };
}

image!(
    ARCHWING_CHASSIS,
    "sub_icons/archwing/prime_chassis_128x128.png"
);
image!(
    ARCHWING_SYSTEMS,
    "sub_icons/archwing/prime_systems_128x128.png"
);
image!(ARCHWING_WINGS, "sub_icons/archwing/prime_wings_128x128.png");
image!(BLUEPRINT, "sub_icons/blueprint_128x128.png");
image!(BAND, "sub_icons/pets/prime_band_128x128.png");
image!(BUCKLE, "sub_icons/pets/prime_buckle_128x128.png");
image!(
    SENTINEL_CARAPACE,
    "sub_icons/sentinel/prime_carapace_128x128.png"
);
image!(CEREBRUM, "sub_icons/sentinel/prime_cerebrum_128x128.png");
image!(
    SENTINEL_SYSTEMS,
    "sub_icons/sentinel/prime_systems_128x128.png"
);
image!(
    WARFRAME_CHASSIS,
    "sub_icons/warframe/prime_chassis_128x128.png"
);
image!(WEAPON_BARREL, "sub_icons/weapon/prime_barrel_128x128.png");
image!(BLADE, "sub_icons/weapon/prime_blade_128x128.png");
image!(WEAPON_BOOT, "sub_icons/weapon/prime_boot_128x128.png");
image!(
    WEAPON_CARAPACE,
    "sub_icons/weapon/prime_carapace_128x128.png"
);
image!(
    WEAPON_CEREBRUM,
    "sub_icons/weapon/prime_cerebrum_128x128.png"
);
image!(CHAIN, "sub_icons/weapon/prime_chain_128x128.png");
image!(
    WEAPON_GAUNTLET,
    "sub_icons/weapon/prime_gauntlet_128x128.png"
);
image!(WEAPON_GUARD, "sub_icons/weapon/prime_guard_128x128.png");
image!(WEAPON_HANDLE, "sub_icons/weapon/prime_handle_128x128.png");
image!(WEAPON_LINK, "sub_icons/weapon/prime_link_128x128.png");
image!(
    WEAPON_RECEIVER,
    "sub_icons/weapon/prime_receiver_128x128.png"
);
image!(WEAPON_STOCK, "sub_icons/weapon/prime_stock_128x128.png");
image!(WEAPON_SYSTEMS, "sub_icons/weapon/prime_systems_128x128.png");

pub(crate) const EMBEDDED_PART_ASSETS: &[EmbeddedAsset] = &[
    asset!(
        "sub_icons/archwing/prime_chassis_128x128.png",
        ARCHWING_CHASSIS
    ),
    asset!(
        "sub_icons/archwing/prime_systems_128x128.png",
        ARCHWING_SYSTEMS
    ),
    asset!("sub_icons/archwing/prime_wings_128x128.png", ARCHWING_WINGS),
    asset!("sub_icons/blueprint_128x128.png", BLUEPRINT),
    asset!("sub_icons/pets/prime_band_128x128.png", BAND),
    asset!("sub_icons/pets/prime_buckle_128x128.png", BUCKLE),
    asset!(
        "sub_icons/sentinel/prime_carapace_128x128.png",
        SENTINEL_CARAPACE
    ),
    asset!("sub_icons/sentinel/prime_cerebrum_128x128.png", CEREBRUM),
    asset!(
        "sub_icons/sentinel/prime_systems_128x128.png",
        SENTINEL_SYSTEMS
    ),
    asset!(
        "sub_icons/warframe/prime_chassis_128x128.png",
        WARFRAME_CHASSIS
    ),
    asset!("sub_icons/warframe/prime_helmet_128x128.png", CEREBRUM),
    asset!(
        "sub_icons/warframe/prime_systems_128x128.png",
        SENTINEL_SYSTEMS
    ),
    asset!("sub_icons/weapon/prime_barrel_128x128.png", WEAPON_BARREL),
    asset!("sub_icons/weapon/prime_blade_128x128.png", BLADE),
    asset!("sub_icons/weapon/prime_boot_128x128.png", WEAPON_BOOT),
    asset!(
        "sub_icons/weapon/prime_carapace_128x128.png",
        WEAPON_CARAPACE
    ),
    asset!(
        "sub_icons/weapon/prime_cerebrum_128x128.png",
        WEAPON_CEREBRUM
    ),
    asset!("sub_icons/weapon/prime_chain_128x128.png", CHAIN),
    asset!("sub_icons/weapon/prime_disc_128x128.png", BLADE),
    asset!(
        "sub_icons/weapon/prime_gauntlet_128x128.png",
        WEAPON_GAUNTLET
    ),
    asset!("sub_icons/weapon/prime_grip_128x128.png", BAND),
    asset!("sub_icons/weapon/prime_guard_128x128.png", WEAPON_GUARD),
    asset!("sub_icons/weapon/prime_handle_128x128.png", WEAPON_HANDLE),
    asset!("sub_icons/weapon/prime_head_128x128.png", BLADE),
    asset!("sub_icons/weapon/prime_holster_128x128.png", BAND),
    asset!("sub_icons/weapon/prime_limb_128x128.png", BLADE),
    asset!("sub_icons/weapon/prime_link_128x128.png", WEAPON_LINK),
    asset!("sub_icons/weapon/prime_ornament_128x128.png", BUCKLE),
    asset!(
        "sub_icons/weapon/prime_receiver_128x128.png",
        WEAPON_RECEIVER
    ),
    asset!("sub_icons/weapon/prime_stars_128x128.png", BLADE),
    asset!("sub_icons/weapon/prime_stock_128x128.png", WEAPON_STOCK),
    asset!("sub_icons/weapon/prime_string_128x128.png", CHAIN),
    asset!("sub_icons/weapon/prime_systems_128x128.png", WEAPON_SYSTEMS),
];

pub(crate) fn embedded_part(source: &str, id: &str) -> Option<&'static EmbeddedAsset> {
    (source == "market")
        .then(|| EMBEDDED_PART_ASSETS.iter().find(|asset| asset.id == id))
        .flatten()
}

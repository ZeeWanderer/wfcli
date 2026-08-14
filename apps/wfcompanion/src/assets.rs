pub(crate) struct EmbeddedImage {
    pub key: &'static str,
    pub bytes: &'static [u8],
}

pub(crate) struct EmbeddedAsset {
    pub id: &'static str,
    pub image: &'static EmbeddedImage,
}

const FORMA_IMAGE: EmbeddedImage = EmbeddedImage {
    key: "forma.png",
    bytes: include_bytes!("../assets/forma.png"),
};

pub(crate) const FORMA_ASSET: EmbeddedAsset = EmbeddedAsset {
    id: "forma.png",
    image: &FORMA_IMAGE,
};

pub(crate) fn embedded_asset(source: &str, id: &str) -> Option<&'static EmbeddedAsset> {
    (source == "builtin" && id == FORMA_ASSET.id).then_some(&FORMA_ASSET)
}

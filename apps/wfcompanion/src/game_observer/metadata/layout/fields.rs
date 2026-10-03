use pelite::pe64::{Pe, PeFile};
use serde::Serialize;

use super::super::super::executable::{descriptor, function_range, signature, signature_in};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub(crate) struct StoreFields {
    pub(crate) category: u64,
    pub(crate) resource: u64,
    pub(crate) description: u64,
    pub(crate) flags: u64,
    pub(crate) exclusion: u64,
    pub(crate) start: u64,
    pub(crate) expiry: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub(crate) struct ManifestFields {
    pub(crate) store_vector: u64,
    pub(crate) store_stride: u64,
    pub(crate) variant_vector: u64,
    pub(crate) variant_stride: u64,
    pub(crate) variant_modes: u64,
}

const ELIGIBILITY: &str = "
    48 8b 81 u4 f2 0f 10 0d ${'}
    48 85 c0 74 0e 0f 57 c0 f2 48 0f 2a c0 66 0f 2f c1 77 1a
    48 8b 81 u4 48 85 c0 74 11
    0f 57 c0 f2 48 0f 2a c0 66 0f 2f c1 73 03 32 c0 c3
    0f b6 81 u4 c0 e8 05 24 01 c3
";

fn named(name: &str) -> String {
    format!(r#"48 8d 15 ${{ [8] *{{ "{name}" 00 }} }}"#)
}

pub(super) fn discover(image: PeFile<'_>) -> Result<(StoreFields, ManifestFields, u64), String> {
    let category = signature::<2>(
        image,
        "StoreItem category",
        &format!(
            "{} 48 8b cb ff 90 38 01 00 00 48 8d 97 u4 48 8b cb e8 ????",
            named("mProductCategory")
        ),
    )?;
    let owner = function_range(image, category[0])?;
    let field = |name: &str, access: &str| {
        signature_in::<2>(
            image,
            name,
            &format!("{} {access}", named(name)),
            owner.clone(),
        )
        .map(|found| u64::from(found[1]))
    };
    let resource = field(
        "mTypeName",
        "48 8b cb ff 90 38 01 00 00 48 8d 4f u1 48 8b d3",
    )?;
    if resource >= 0x80 {
        return Err("invalid StoreItem type displacement".into());
    }
    let eligibility = signature::<5>(image, "StoreItem eligibility", ELIGIBILITY)?;
    let fields = StoreFields {
        category: category[1].into(),
        resource,
        description: field(
            "mLocalizeDescTag",
            "48 8b cb ff 90 38 01 00 00 48 8b 03 48 8d 97 u4 48 8b cb ff 90 20 01 00 00",
        )?,
        flags: field(
            "mShowInMarket",
            "48 8b cb ff 90 38 01 00 00 0f b6 87 u4 48 8d 55 ? c0 e8 05 48 8b cb 24 01",
        )?,
        exclusion: field(
            "mTintIconToTheme",
            "[0-48] ff 90 38 01 00 00 48 8d b7 u4 48 8b cb 0f b6 06 48 8d 55 ? d0 e8 24 01",
        )?,
        start: field(
            "mEmbargoLiftDate",
            "48 8b cb ff 90 38 01 00 00 48 8d 97 u4 48 8b cb e8 ????",
        )?,
        expiry: field(
            "mExpiryDate",
            "48 8b cb ff 90 38 01 00 00 48 8d 97 u4 48 8b cb e8 ????",
        )?,
    };
    signature_in::<1>(
        image,
        "StoreItem codex exclusion",
        &format!(
            "{} 48 8b cb ff 90 38 01 00 00 0f b6 06 48 8d 55 ? 24 01 48 8b cb",
            named("mExcludeFromCodex")
        ),
        owner.clone(),
    )?;
    let exclusion = signature_in::<2>(image, "StoreItem flag pointer", "48 8d b7 u4", owner)?;
    if fields.start != u64::from(eligibility[1])
        || fields.expiry != u64::from(eligibility[3])
        || fields.flags != u64::from(eligibility[4])
        || fields.exclusion != u64::from(exclusion[1])
    {
        return Err("StoreItem accessors disagree".into());
    }
    let used = [
        (fields.category, 1),
        (fields.resource, 8),
        (fields.description, 4),
        (fields.flags, 1),
        (fields.exclusion, 1),
        (fields.start, 8),
        (fields.expiry, 8),
    ];
    for (index, &(offset, width)) in used.iter().enumerate() {
        if !(0x18..0x10000).contains(&offset)
            || !offset.is_multiple_of(width)
            || used[..index]
                .iter()
                .any(|&(other, size)| offset < other + size && other < offset + width)
        {
            return Err("invalid or overlapping StoreItem fields".into());
        }
    }

    let store = signature::<3>(
        image,
        "StoreManifest vector",
        &format!(
            "{} 48 8b cf ff 90 38 01 00 00 48 8d 53 u1 45 33 c0 48 8b cf e8 ${{'}}",
            named("mStoreItems")
        ),
    )?;
    let store_entry = signature_in::<3>(
        image,
        "StoreManifest entries",
        "4c 8d 05 ${'} 48 8b d6 48 8b cb e8 ???? 48 83 c3 u1 48 3b df 75 ?",
        helper_range(image, store[2])?,
    )?;
    let (store_type, _) = descriptor(image, "StoreItem", "/Lotus/Types/Game/")?;
    if u64::from(store_entry[1]) != store_type {
        return Err("StoreManifest serializer has a different item type".into());
    }
    let count = signature_in::<2>(
        image,
        "StoreManifest entry count",
        "8b 47 08 48 c1 e8 u1 48 89 44 24 ?",
        helper_range(image, store[2])?,
    )?;
    if !(3..7).contains(&count[1]) || store_entry[2] != 1 << count[1] {
        return Err("StoreManifest entry sizes disagree".into());
    }
    signature_in::<1>(
        image,
        "StoreManifest vector header",
        "48 8b 1f 8b 7f 08 48 03 fb",
        helper_range(image, store[2])?,
    )?;

    let variants = signature::<3>(
        image,
        "VariantManifest vector",
        &format!(
            "{} 49 8b cc ff 90 38 01 00 00 48 8d 56 u1 49 8b cc e8 ${{'}}",
            named("mWeaponVariantMap")
        ),
    )?;
    let variant_entry = signature_in::<3>(
        image,
        "VariantManifest entries",
        "48 8b 03 48 8d 53 u1 48 8d 4d ? 48 89 45 ? e8 ????
         48 8d 55 ? 48 8b ce e8 ???? 48 8b 06 48 8b ce ff 50 60
         48 8d 4d ? e8 ???? 48 83 c3 u1 48 3b df 75 ?",
        helper_range(image, variants[2])?,
    )?;
    signature_in::<1>(
        image,
        "VariantManifest vector header",
        "48 8b 1f 8b 7f 08 48 03 fb",
        helper_range(image, variants[2])?,
    )?;
    let vectors = ManifestFields {
        store_vector: store[1].into(),
        store_stride: store_entry[2].into(),
        variant_vector: variants[1].into(),
        variant_stride: variant_entry[2].into(),
        variant_modes: variant_entry[1].into(),
    };
    if ![
        vectors.store_vector,
        vectors.store_stride,
        vectors.variant_vector,
        vectors.variant_stride,
        vectors.variant_modes,
    ]
    .iter()
    .all(|offset| (8..0x80).contains(offset) && offset.is_multiple_of(8))
        || vectors.variant_modes + 16 > vectors.variant_stride
    {
        return Err("invalid manifest layout".into());
    }
    Ok((fields, vectors, eligibility[2].into()))
}

fn helper_range(image: PeFile<'_>, start: u32) -> Result<std::ops::Range<u32>, String> {
    let code = image.headers().code_range();
    let end = start
        .checked_add(0x400)
        .filter(|_| code.contains(&start))
        .map(|end| end.min(code.end))
        .ok_or("manifest serializer outside executable code")?;
    // Unwind metadata splits these helpers at exception-handling boundaries.
    Ok(start..end)
}

#[cfg(test)]
pub(super) mod tests;

WITH split_paths AS (
    select distinct bucket,
        key,
        split(key, '/') as path_parts
    from pdr_inventory.pdr_inventory_prod_data_all
    where key not like '%/'
        AND is_latest = true
        AND coalesce(is_delete_marker, false) = false
        and bucket in (
            'nyec-pdr-prod-bronx',
            'nyec-pdr-prod-healtheconnections',
            'nyec-pdr-prod-healthelink',
            'nyec-pdr-prod-healthix',
            'nyec-pdr-prod-hixny',
            'nyec-pdr-prod-rochester'
        )
),
find_index as(
    select bucket,
        key,
        path_parts,
        case
            when path_parts [ 1 ] in ('backload', 'error', 'processed')
            and path_parts [ 2 ] in ('backload', 'error', 'processed')
            and path_parts [ 3 ] in ('backload', 'error', 'processed') then 3
            when path_parts [ 1 ] in ('backload', 'error', 'processed')
            and path_parts [ 2 ] in ('backload', 'error', 'processed') then 2
            when path_parts [ 1 ] in ('backload', 'error', 'processed') then 1
            else 0
        end as offset_num,
        element_at(
            filter(
                sequence(1, cardinality(path_parts)),
                i->path_parts [ i ] in ('ccd', 'trn')
            ),
            1
        ) as file_type_index
    from split_paths
),
extract_aa as (
    SELECT bucket,
        key,
        case
            when file_type_index is not null
            and file_type_index > offset_num + 1 then array_join(
                slice(
                    path_parts,
                    offset_num + 1,
                    file_type_index - (offset_num + 1)
                ),
                '/'
            )
            when file_type_index is null then 'NO FILE TYPE FOUND'
            else 'MISSING AA'
        end as assigning_authority
    FROM find_index
    WHERE path_parts [ file_type_index ] = 'ccd'
        and offset_num = 0
),
add_rn as (
    SELECT bucket,
        key,
        assigning_authority,
        ROW_NUMBER() OVER(
            PARTITION BY assigning_authority
            order by random()
        ) as rn
    FROM extract_aa
    where assigning_authority in (
            select assigning_authority
            from hospital_aa_reference
        )
)
SELECT bucket,
    key
from add_rn
where rn <= 20000
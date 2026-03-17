#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import json
import re
import time
from typing import Any, Dict, List, Optional, Tuple

from arcgis.gis import GIS
from arcgis.features import FeatureLayerCollection

# ------------------------
# HOST URL :- https://dev001.networks.vertigisapps.com
# USERNAME :- <admin account>
# PASSWORD :- <admin login>
# ------------------------

def prompt_for_inputs():
    host = input("Enter HOST URL: ").strip().rstrip("/")
    username = input("Enter Portal Username: ").strip()
    password = input("Enter Portal Password: ").strip()
    return host, username, password

HOST, USERNAME, PASSWORD = prompt_for_inputs()
PORTAL_URL = f"{HOST}/portal"
VERIFY_CERT = True  # set to False for self-signed/invalid certs

JOBM_USER_ROLE_NAME = "JobM_UserRole"
GROUP_TITLE = "Job Management Users"
FOLDER_TITLE = "JobManagementOneGas"
JOBM_SERVICE_NAME = "JobManagementSystemOneGas"

_POLL_DELAY_SEC = 2
_POLL_MAX_TRIES = 20

def _rest_base(gis: GIS) -> str:
    return gis._portal.resturl.rstrip("/")

def _get(gis: GIS, url: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    p = {"f": "json"}
    if params:
        p.update(params)
    return gis._con.get(url, p) or {}

def _post(gis: GIS, url: str, data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    d = {"f": "json"}
    if data:
        d.update(data)
    return gis._con.post(url, postdata=d) or {}

def _connect() -> Tuple[Optional[GIS], Optional[str]]:
    try:
        gis = GIS(PORTAL_URL, USERNAME, PASSWORD, verify_cert=VERIFY_CERT)
        _get(gis, f"{_rest_base(gis)}/portals/self")
        return gis, None
    except Exception as e:
        msg = str(e)
        hints = [
            f"Portal: {PORTAL_URL}",
            f"Username: {USERNAME}",
            "Login failed. Fixes:",
            "  • Verify username/password by signing into the Portal web UI.",
            "  • If using SAML/IWA-only, use a built-in admin or OAuth/Pro sign-in.",
            "  • For self-signed certs, set VERIFY_CERT=False.",
        ]
        return None, msg + "\n" + "\n".join(hints)

def _jobm_user_privileges() -> List[str]:
    return [
        "portal:user:viewOrgUsers",
        "portal:user:viewOrgItems",
        "portal:user:joinGroup",
        "portal:user:viewOrgGroups",
        "premium:user:geocode",
        "premium:user:networkanalysis",
        "features:user:edit",
        "features:user:fullEdit",
        "features:user:manageVersions",
    ]

def _get_role_id(role_obj: Any) -> Optional[str]:
    for attr in ("id", "roleId", "role_id"):
        val = getattr(role_obj, attr, None)
        if val:
            return val
    props = getattr(role_obj, "properties", None)
    if isinstance(props, dict):
        for k in ("id", "roleId"):
            if k in props:
                return props[k]
    return None

def _get_portal_id(gis: GIS) -> Optional[str]:
    try:
        pid = getattr(gis.properties, "id", None)
        if pid:
            return pid
    except Exception:
        pass
    try:
        info = _get(gis, f"{_rest_base(gis)}/portals/self")
        return info.get("id")
    except Exception:
        return None

def ensure_custom_role(gis: GIS, role_name: str, description: str, privileges: List[str]) -> str:
    role_mgr = gis.users.roles
    portal_id = _get_portal_id(gis)
    if not portal_id:
        return f"[Role] Portal id not found; cannot create/update '{role_name}'."

    existing = next((r for r in role_mgr.all() if r.name == role_name), None)

    def _is_success(payload: Any) -> bool:
        if not isinstance(payload, dict):
            return False
        if payload.get("success") is True:
            return True
        status = payload.get("status")
        return isinstance(status, str) and status.lower() == "success"

    if existing:
        role_id = _get_role_id(existing)
        if not role_id:
            return f"[Role] '{role_name}' exists but id missing; cannot update."
        upd_url = f"{_rest_base(gis)}/portals/{portal_id}/roles/{role_id}/update"
        data = _post(gis, upd_url, {"name": role_name, "description": description})
        if not _is_success(data):
            return f"[Role] Failed updating '{role_name}': {data}"
        set_url = f"{_rest_base(gis)}/portals/{portal_id}/roles/{role_id}/setPrivileges"
        data2 = _post(gis, set_url, {"privileges": json.dumps({"privileges": privileges})})
        if not _is_success(data2):
            return f"[Role] Updated but failed to set privileges for '{role_name}': {data2}"
        return f"[Role] '{role_name}' updated."

    new_role = role_mgr.create(name=role_name, description=description)
    role_id = _get_role_id(new_role)
    if not role_id:
        return f"[Role] Created '{role_name}' but role id missing; cannot set privileges."
    set_url = f"{_rest_base(gis)}/portals/{portal_id}/roles/{role_id}/setPrivileges"
    data3 = _post(gis, set_url, {"privileges": json.dumps({"privileges": privileges})})
    if not _is_success(data3):
        return f"[Role] '{role_name}' created but failed to set privileges: {data3}"
    return f"[Role] '{role_name}' created and privileges set."

def ensure_group(gis: GIS, title: str) -> Tuple[str, str]:
    q = f'title:"{title}"'
    matches = gis.groups.search(query=q, max_groups=2) or []
    if matches:
        g = matches[0]
        return g.id, f"[Group] '{title}' exists (id={g.id})."
    g = gis.groups.create(title=title, tags="job,management", access="org")
    return g.id, f"[Group] '{title}' created (id={g.id})."

def _extract_folder_id(folder_obj: Any) -> Optional[str]:
    if folder_obj is None:
        return None
    fid = getattr(folder_obj, "id", None)
    if fid:
        return fid
    props = getattr(folder_obj, "properties", None)
    if isinstance(props, dict) and props.get("id"):
        return props["id"]
    if isinstance(folder_obj, dict):
        return folder_obj.get("id")
    return None

def ensure_folder(gis: GIS, owner: str, folder_title: str) -> Tuple[str, str]:
    try:
        user = gis.users.get(owner)
        for f in getattr(user, "folders", []) or []:
            name = getattr(f, "name", None) or (f.get("name") if isinstance(f, dict) else None)
            title = getattr(f, "title", None) or (f.get("title") if isinstance(f, dict) else None)
            if name == folder_title or title == folder_title:
                fid = _extract_folder_id(f)
                if fid:
                    return fid, f"[Folder] '{folder_title}' exists (id={fid})."
    except Exception:
        pass
    try:
        folder_obj = gis.content.folders.get(folder=folder_title, owner=owner)
        fid = _extract_folder_id(folder_obj)
        if fid:
            return fid, f"[Folder] '{folder_title}' exists (id={fid})."
    except Exception:
        pass
    _ = gis.content.folders.create(folder=folder_title, owner=owner)
    time.sleep(1.0)
    folder_obj = gis.content.folders.get(folder=folder_title, owner=owner)
    fid = _extract_folder_id(folder_obj) or ""
    return fid, f"[Folder] '{folder_title}' created (id={fid})."

def _ensure_content_root_initialized(gis: GIS, owner: str) -> None:
    try:
        gis.content.folders.create(folder="__init__", owner=owner)
    except Exception:
        pass

def _hosting_available(gis: GIS) -> bool:
    try:
        servers = _get(gis, f"{_rest_base(gis)}/portals/self/servers") or {}
        return any(bool(s.get("isHosted")) for s in (servers.get("servers") or []))
    except Exception:
        return False

def _is_view_item(item) -> bool:
    try:
        p = getattr(item, "properties", None)
        if p:
            if isinstance(p, dict) and p.get("isView") is True:
                return True
            if hasattr(p, "isView") and getattr(p, "isView") is True:
                return True
    except Exception:
        pass
    return False

def _service_is_hosted(item) -> bool:
    try:
        tks = getattr(item, "typeKeywords", []) or []
        if isinstance(tks, str):
            tks = [s.strip() for s in tks.split(",")]
        s = {str(x).strip() for x in tks}
        return ("Hosted Service" in s) or ("Hosted" in s)
    except Exception:
        return False

def _adopt_existing_if_present(gis: GIS, owner: str, service_name: str):
    items = (gis.content.search(
        query=f'title:"{service_name}" AND type:"Feature Service"',
        max_items=20,
    ) or [])
    if not items:
        items = (gis.content.search(
            query=f'title:"{service_name}" AND type:"Feature Layer"',
            max_items=20,
        ) or [])

    me = gis.users.me
    is_admin = getattr(me, "role", "") == "org_admin"

    for it in items:
        try:
            if _is_view_item(it):
                continue
            if it.owner != owner and is_admin:
                try:
                    it.reassign_to(owner)
                except Exception:
                    pass
            return it
        except Exception:
            continue
    return None

def _create_service_via_rest(gis: GIS, owner: str, service_name: str) -> Dict[str, Any]:
    create_url = f"{_rest_base(gis)}/content/users/{owner}/createService"
    service_def = {
        "name": service_name,
        "serviceDescription": "Job Management System Service",
        "isView": False,
        "hasStaticData": False,
        "supportedQueryFormats": "JSON",
        "capabilities": "Create,Delete,Query,Update,Editing,Sync",
        "maxRecordCount": 2000,
        "spatialReference": {"wkid": 4326},
        "allowGeometryUpdates": True,
        "xssPreventionInfo": {
            "xssPreventionEnabled": True,
            "xssPreventionRule": "InputOnly",
            "xssInputFilter": "sanitized",
        },
        "editorTrackingInfo": {
            "enableEditorTracking": True,
            "enableOwnershipAccessControl": False,
            "allowOthersToUpdate": True,
            "allowOthersToDelete": True,
        },
    }
    return _post(
        gis,
        create_url,
        {"createParameters": json.dumps(service_def), "outputType": "featureService"},
    )

def _base_featureserver_url(item) -> str:
    url = getattr(item, "url", "") or ""
    m = re.search(r"(.*?/FeatureServer)(?:/[0-9]+)?$", url, flags=re.I)
    return m.group(1) if m else url

def _get_flc(gis: GIS, item) -> FeatureLayerCollection:
    base = _base_featureserver_url(item)
    if not base:
        return FeatureLayerCollection.fromitem(item)
    return FeatureLayerCollection(base, gis)

def _get_layer_by_name(flc: FeatureLayerCollection, name: str):
    lname = name.lower()
    return next((l for l in (flc.layers or []) if getattr(l.properties, "name", "").lower() == lname), None)

def _get_table_by_name(flc: FeatureLayerCollection, name: str):
    tname = name.lower()
    return next((t for t in (flc.tables or []) if getattr(t.properties, "name", "").lower() == tname), None)

def _add_schema(flc: FeatureLayerCollection, payload: Dict[str, Any]) -> None:
    if not payload:
        return
    flc.manager.add_to_definition(payload)

def _enable_jobs_attachments(flc: FeatureLayerCollection) -> None:
    jobs = _get_layer_by_name(flc, "Jobs")
    if not jobs:
        return
    has_att = getattr(jobs.properties, "hasAttachments", None)
    if not has_att:
        jobs.manager.update_definition({"hasAttachments": True})

def _ensure_relationship(flc: FeatureLayerCollection) -> None:
    jobs = _get_layer_by_name(flc, "Jobs")
    jc = _get_table_by_name(flc, "JobChange")
    if not jobs or not jc:
        return

    rels = getattr(jobs.properties, "relationships", []) or []
    existing = {
        (rel.get("relatedTableId") if isinstance(rel, dict) else getattr(rel, "relatedTableId", None))
        for rel in rels
    }
    if getattr(jc.properties, "id", None) in existing:
        return

    payload = {
        "layers": [
            {
                "id": getattr(jobs.properties, "id", None),
                "relationships": [
                    {
                        "name": "Jobs_JobChange",
                        "relatedTableId": getattr(jc.properties, "id", None),
                        "cardinality": "esriRelCardinalityOneToMany",
                        "role": "esriRelRoleOrigin",
                        "keyField": "GlobalID",
                        "composite": True,
                    }
                ],
            }
        ]
    }
    try:
        flc.manager.add_to_definition(payload)
        return
    except Exception:
        pass
    try:
        fallback = {
            "tables": [
                {
                    "id": getattr(jc.properties, "id", None),
                    "relationships": [
                        {
                            "name": "Jobs_JobChange",
                            "relatedTableId": getattr(jobs.properties, "id", None),
                            "cardinality": "esriRelCardinalityManyToOne",
                            "role": "esriRelRoleDestination",
                            "keyField": "jobglobalid",
                            "composite": True,
                        }
                    ],
                }
            ]
        }
        flc.manager.add_to_definition(fallback)
    except Exception:
        pass

def _wait_fs_ready(gis: GIS, fs_item) -> bool:
    url = f"{_base_featureserver_url(fs_item)}?f=json"
    tries = 0
    while tries < _POLL_MAX_TRIES:
        try:
            data = _get(gis, url)
            if isinstance(data, dict) and "layers" in data:
                return True
        except Exception:
            pass
        time.sleep(_POLL_DELAY_SEC)
        tries += 1
    return False

def _preflight_summary(gis: GIS) -> Dict[str, Any]:
    me = gis.users.me
    role = getattr(me, "role", "") if me else ""
    privs = set(getattr(me, "privileges", []) or [])
    return {
        "hosting": _hosting_available(gis),
        "role": role,
        "publisherPriv": any(p.startswith("portal:publisher") for p in privs),
    }

def _try_create_hosted_strict(gis: GIS, owner: str, name: str):
    resp = _create_service_via_rest(gis, owner, name)
    if resp.get("success"):
        return gis.content.get(resp["itemId"]), None
    msg_l = json.dumps(resp).lower()
    if ("already exist" in msg_l) or ("already exists" in msg_l) or ("name not available" in msg_l):
        return None, "name_conflict"
    return None, msg_l or "create_failed"

def _find_blocking_item(gis: GIS, owner: str, name: str):
    hits = gis.content.search(
        query=f'title:"{name}" AND (type:"Feature Service" OR type:"Feature Layer")',
        max_items=50,
    ) or []
    hosted_same_owner = [
        it for it in hits
        if getattr(it, "owner", "") == owner and ("Hosted Service" in (getattr(it, "typeKeywords", []) or []))
    ]
    if hosted_same_owner:
        return hosted_same_owner[0]
    return hits[0] if hits else None

def ensure_feature_service(gis: GIS, service_name: str, folder_title: str, group_id: Optional[str]) -> str:
    owner = getattr(gis.users.me, "username", USERNAME)
    item = _adopt_existing_if_present(gis, owner, service_name)
    if item:
        base_url = _base_featureserver_url(item) or "(no url)"
        if _is_view_item(item):
            try:
                folder_obj = gis.content.folders.get(folder=folder_title, owner=owner)
                fid = _extract_folder_id(folder_obj)
                if fid and getattr(item, "ownerFolder", None) != fid:
                    item.move(folder=fid)
            except Exception:
                pass
            if group_id:
                try:
                    item.share(groups=[group_id], org=True)
                except Exception:
                    pass
            return f"[FS] Service '{service_name}' already exists (itemId={item.id}, url={base_url}); item is a View so schema was not changed."
        _wait_fs_ready(gis, item)
        try:
            _ensure_schema_bundle(gis, item)
        except Exception:
            pre = _preflight_summary(gis)
            if pre.get("hosting"):
                hosted_item, err = _try_create_hosted_strict(gis, owner, service_name)
                if hosted_item is None:
                    if err == "name_conflict":
                        blocker = _find_blocking_item(gis, owner, service_name)
                        if blocker:
                            return (
                                f"[FS] Service '{service_name}' exists but schema couldn't be changed (likely non-hosted). "
                                f"Also could not create a hosted replacement with the SAME name because it’s already in use.\n"
                                f"Blocking item → title='{blocker.title}', owner='{blocker.owner}', itemId={blocker.id}, url={getattr(blocker, 'url', '') or '(no url)'}.\n"
                                f"Action: Delete/rename or transfer the blocking service, then re-run."
                            )
                        return (
                            f"[FS] Service '{service_name}' exists but schema couldn't be changed (likely non-hosted). "
                            f"Also could not create a hosted replacement with the same name due to a name conflict.\n"
                            f"Action: Delete/rename the existing hosted service titled '{service_name}' for owner '{owner}', then re-run."
                        )
                    return (
                        f"[FS] Service '{service_name}' exists but schema couldn't be changed (likely non-hosted). "
                        f"Tried to create hosted replacement with the same name; failed: {err}"
                    )
                _wait_fs_ready(gis, hosted_item)
                try:
                    folder_obj = gis.content.folders.get(folder=folder_title, owner=owner)
                    fid = _extract_folder_id(folder_obj)
                    if fid and getattr(hosted_item, "ownerFolder", None) != fid:
                        hosted_item.move(folder=fid)
                except Exception:
                    pass
                flc2 = _get_flc(gis, hosted_item)
                _add_schema(flc2, {
                    "layers": [jobs_layer_def()],
                    "tables": [users_table_def(), groups_table_def(), jobchange_table_def()],
                })
                time.sleep(1.0)
                flc2 = _get_flc(gis, hosted_item)
                _enable_jobs_attachments(flc2)
                _ensure_relationship(flc2)
                if group_id:
                    try:
                        hosted_item.share(groups=[group_id], org=True)
                    except Exception:
                        pass
                return (
                    f"[FS] Replaced non-hosted '{service_name}' with a Hosted service of the SAME name "
                    f"(itemId={hosted_item.id}, url={_base_featureserver_url(hosted_item)}). "
                    "Full schema, attachments, relationship, and sharing applied."
                )
            else:
                return (
                    f"[FS] Service '{service_name}' exists but schema couldn't be changed (likely non-hosted / enterprise). "
                    "No Hosting Server detected, so a hosted replacement could not be created."
                )
        try:
            folder_obj = gis.content.folders.get(folder=folder_title, owner=owner)
            fid = _extract_folder_id(folder_obj)
            if fid and getattr(item, "ownerFolder", None) != fid:
                item.move(folder=fid)
        except Exception:
            pass
        if group_id:
            try:
                item.share(groups=[group_id], org=True)
            except Exception:
                pass
        return (
            f"[FS] Service '{service_name}' already existed (itemId={item.id}, url={_base_featureserver_url(item)}); "
            f"ensured Jobs layer, Users/Groups/JobChange tables, relationship, attachments, and sharing."
        )
    pre = _preflight_summary(gis)
    if not pre["hosting"]:
        return (
            "[FS] Skipped creation: No Hosting Server present in Portal (checked /portals/self/servers). "
            "If hosting exists, ensure this account can publish to it."
        )
    if not (pre["role"] in ("org_admin", "org_publisher") or pre["publisherPriv"]):
        return f"[FS] Skipped creation: User '{owner}' lacks publisher/admin privileges."
    _ensure_content_root_initialized(gis, owner)
    item, err = _try_create_hosted_strict(gis, owner, service_name)
    if item is None:
        if err == "name_conflict":
            blocker = _find_blocking_item(gis, owner, service_name)
            if blocker:
                return (
                    f"[FS] Skipped creation: A hosted service with name '{service_name}' already exists.\n"
                    f"Blocking item → title='{blocker.title}', owner='{blocker.owner}', itemId={blocker.id}, "
                    f"url={getattr(blocker, 'url', '') or '(no url)'}.\n"
                    f"Action: Delete/rename or transfer that service, then re-run."
                )
            return (
                f"[FS] Skipped creation: Service name '{service_name}' is already in use for '{owner}'. "
                f"Delete/rename the existing hosted service, then re-run."
            )
        return f"[FS] Create failed: {err}"
    try:
        folder_obj = gis.content.folders.get(folder=folder_title, owner=owner)
        fid = _extract_folder_id(folder_obj)
        if fid and getattr(item, "ownerFolder", None) != fid:
            item.move(folder=fid)
    except Exception:
        pass
    _wait_fs_ready(gis, item)
    flc = _get_flc(gis, item)
    _add_schema(flc, {
        "layers": [jobs_layer_def()],
        "tables": [users_table_def(), groups_table_def(), jobchange_table_def()],
    })
    time.sleep(1.0)
    flc = _get_flc(gis, item)
    _enable_jobs_attachments(flc)
    _ensure_relationship(flc)
    if group_id:
        try:
            item.share(groups=[group_id], org=True)
        except Exception:
            pass
    return f"[FS] '{service_name}' ready (itemId={item.id}, url={_base_featureserver_url(item)})."

def jobs_layer_def() -> Dict[str, Any]:
    return {
        "name": "Jobs",
        "type": "Feature Layer",
        "geometryType": "esriGeometryPolygon",
        "displayField": "jobid",
        "fields": [
            {"name": "OBJECTID", "type": "esriFieldTypeOID", "alias": "OBJECTID"},
            {"name": "GlobalID", "type": "esriFieldTypeGlobalID", "alias": "GlobalID"},
            {"name": "jobid", "type": "esriFieldTypeString", "alias": "Job ID", "length": 64},
            {"name": "name", "type": "esriFieldTypeString", "alias": "Job Name", "length": 255},
            {"name": "description", "type": "esriFieldTypeString", "alias": "Description", "length": 2000},
            {"name": "status", "type": "esriFieldTypeString", "alias": "Status", "length": 50},
            {"name": "jobtype", "type": "esriFieldTypeString", "alias": "Job Type", "length": 50},
            {"name": "tags", "type": "esriFieldTypeString", "alias": "Tags", "length": 2000},
            {"name": "assignedto", "type": "esriFieldTypeString", "alias": "Assigned To", "length": 128},
            {"name": "state", "type": "esriFieldTypeString", "alias": "Assignment State", "length": 50},
            {"name": "createdby", "type": "esriFieldTypeString", "alias": "Created By"},
            {"name": "createddate", "type": "esriFieldTypeDate", "alias": "Created Date"},
            {"name": "lastupdated", "type": "esriFieldTypeDate", "alias": "Last Updated"},
            {"name": "versionid", "type": "esriFieldTypeString", "alias": "Version ID", "length": 128},
            {"name": "featureservice", "type": "esriFieldTypeString", "alias": "Feature Service", "length": 128},
            {"name": "assignedsupervisor", "type": "esriFieldTypeString", "alias": "Assigned Supervisor", "length": 128},
            {"name": "startdate", "type": "esriFieldTypeDate", "alias": "Start Date"},
            {"name": "enddate", "type": "esriFieldTypeDate", "alias": "End Date"},
            {"name": "duedate", "type": "esriFieldTypeDate", "alias": "Due Date"},
            {"name": "lastsync", "type": "esriFieldTypeDate", "alias": "Last sync"},
            {"name": "groups", "type": "esriFieldTypeString", "alias": "Groups", "length": 50},
            {"name": "groupid", "type": "esriFieldTypeString", "alias": "Group ID", "length": 64},
            {"name": "isworking", "type": "esriFieldTypeString", "alias": "isworking", "length": 50},
            {"name": "projectid", "type": "esriFieldTypeString", "alias": "Project ID", "length": 64},
            {"name": "contractid", "type": "esriFieldTypeString", "alias": "Contract ID", "length": 64},
            {"name": "actualhrs", "type": "esriFieldTypeDouble", "alias": "Actual Hours"},
        ],
        "objectIdField": "OBJECTID",
        "globalIdField": "GlobalID",
        "capabilities": "Query,Create,Update,Delete,Editing,Sync",
    }

def users_table_def() -> Dict[str, Any]:
    return {
        "name": "Users",
        "type": "Table",
        "fields": [
            {"name": "OBJECTID", "type": "esriFieldTypeOID", "alias": "OBJECTID"},
            {"name": "userid", "type": "esriFieldTypeString", "alias": "User ID", "length": 128},
            {"name": "username", "type": "esriFieldTypeString", "alias": "User Name", "length": 255},
            {"name": "usertype", "type": "esriFieldTypeString", "alias": "User Type", "length": 255},
            {"name": "email", "type": "esriFieldTypeString", "alias": "Email", "length": 255},
            {"name": "role", "type": "esriFieldTypeString", "alias": "Role", "length": 64},
            {"name": "previousrole", "type": "esriFieldTypeString", "alias": "Previous Role", "length": 64},
            {"name": "groups", "type": "esriFieldTypeString", "alias": "Groups", "length": 128},
            {"name": "groupid", "type": "esriFieldTypeString", "alias": "Group ID", "length": 64},
            {"name": "flag", "type": "esriFieldTypeString", "alias": "User Flag", "length": 128},
            {"name": "jobfields", "type": "esriFieldTypeString", "alias": "Job Fields", "length": 255},
            {"name": "GlobalID", "type": "esriFieldTypeGlobalID", "alias": "GlobalID"},
        ],
        "objectIdField": "OBJECTID",
        "globalIdField": "GlobalID",
        "capabilities": "Query,Create,Update,Delete,Editing,Sync",
    }

def groups_table_def() -> Dict[str, Any]:
    return {
        "name": "Groups",
        "type": "Table",
        "fields": [
            {"name": "OBJECTID", "type": "esriFieldTypeOID", "alias": "OBJECTID"},
            {"name": "groupid", "type": "esriFieldTypeString", "alias": "Group ID", "length": 64},
            {"name": "groups", "type": "esriFieldTypeString", "alias": "Groups", "length": 255},
            {"name": "requiredfields", "type": "esriFieldTypeString", "alias": "Required Fields", "length": 255},
            {"name": "resolution", "type": "esriFieldTypeString", "alias": "Conflict Resolution", "length": 255},
            {"name": "hierarchy", "type": "esriFieldTypeString", "alias": "Hierarchy", "length": 255},
            {"name": "deadlineday", "type": "esriFieldTypeString", "alias": "Deadline Days", "length": 255},
            {"name": "selectedtime", "type": "esriFieldTypeString", "alias": "Schedule Run Time", "length": 255},
            {"name": "GlobalID", "type": "esriFieldTypeGlobalID", "alias": "GlobalID"},
        ],
        "objectIdField": "OBJECTID",
        "globalIdField": "GlobalID",
        "capabilities": "Query,Create,Update,Delete,Editing,Sync",
    }

def jobchange_table_def() -> Dict[str, Any]:
    return {
        "name": "JobChange",
        "type": "Table",
        "fields": [
            {"name": "OBJECTID", "type": "esriFieldTypeOID", "alias": "OBJECTID"},
            {"name": "jobglobalid", "type": "esriFieldTypeGUID", "alias": "Job GlobalID"},
            {"name": "jobid", "type": "esriFieldTypeString", "alias": "Job ID (display)", "length": 64},
            {"name": "changetype", "type": "esriFieldTypeString", "alias": "Change Type", "length": 50},
            {"name": "changenotes", "type": "esriFieldTypeString", "alias": "Notes", "length": 1000},
            {"name": "changedby", "type": "esriFieldTypeString", "alias": "Changed By", "length": 128},
            {"name": "changedat", "type": "esriFieldTypeDate", "alias": "Changed At"},
            {"name": "GlobalID", "type": "esriFieldTypeGlobalID", "alias": "GlobalID"},
        ],
        "objectIdField": "OBJECTID",
        "globalIdField": "GlobalID",
        "capabilities": "Query,Create,Update,Delete,Editing,Sync",
    }

def _ensure_schema_bundle(gis: GIS, item) -> None:
    flc = _get_flc(gis, item)
    payload = {"layers": [], "tables": []}
    if not _get_layer_by_name(flc, "Jobs"):
        payload["layers"].append(jobs_layer_def())
    existing_tables = {(getattr(t.properties, "name", "") or "").strip().lower() for t in (flc.tables or [])}
    if "users" not in existing_tables:
        payload["tables"].append(users_table_def())
    if "groups" not in existing_tables:
        payload["tables"].append(groups_table_def())
    if "jobchange" not in existing_tables:
        payload["tables"].append(jobchange_table_def())
    if payload["layers"] or payload["tables"]:
        _add_schema(flc, {k: v for k, v in payload.items() if v})
        time.sleep(1.0)
        flc = _get_flc(gis, item)
    _enable_jobs_attachments(flc)
    _ensure_relationship(flc)

def run_setup_hardcoded() -> List[str]:
    gis, err = _connect()
    if err:
        print("[Login]", err)
        return ["Login failed — see details above."]

    out: List[str] = []

    out.append(
        ensure_custom_role(
            gis,
            JOBM_USER_ROLE_NAME,
            description=(
                "Unified Job Management role: full edit, branch version management, geocoding, "
                "network analysis, and view org content/members/groups."
            ),
            privileges=_jobm_user_privileges(),
        )
    )

    gid, msg = ensure_group(gis, GROUP_TITLE)
    out.append(msg)

    owner = getattr(gis.users.me, "username", USERNAME)
    _, msg2 = ensure_folder(gis, owner, FOLDER_TITLE)
    out.append(msg2)

    out.append(ensure_feature_service(gis, JOBM_SERVICE_NAME, FOLDER_TITLE, gid))

    return out

if __name__ == "__main__":
    for line in run_setup_hardcoded():
        print(line)
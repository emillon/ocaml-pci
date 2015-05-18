open Ctypes

module B = Ffi_bindings.Bindings(Ffi_generated)
module T = Ffi_bindings.Types(Ffi_generated_types)

module U8 = Unsigned.UInt8
module U16 = Unsigned.UInt16

module Pci_dev = struct
  type t = {
    domain : int;
    bus : int;
    dev : int;
    func : int;
    vendor_id : int;
    device_id : int;
    device_class : int;
    irq : int;
    base_addr : nativeint list;
    size : nativeint list;
    rom_base_addr : nativeint;
    rom_size : nativeint;
    phy_slot : string option;
    subsystem_id : (int * int) option;
  }
  let make (_t: B.Pci_dev.t) =
    {
      domain = getf !@_t B.Pci_dev.domain |> U16.to_int;
      bus = getf !@_t B.Pci_dev.bus |> U8.to_int;
      dev = getf !@_t B.Pci_dev.dev |> U8.to_int;
      func = getf !@_t B.Pci_dev.func |> U8.to_int;
      vendor_id = getf !@_t B.Pci_dev.vendor_id |> U16.to_int;
      device_id = getf !@_t B.Pci_dev.device_id |> U16.to_int;
      device_class = getf !@_t B.Pci_dev.device_class |> U16.to_int;
      irq = getf !@_t B.Pci_dev.irq;
      base_addr = getf !@_t B.Pci_dev.base_addr |> CArray.to_list;
      size = getf !@_t B.Pci_dev.size |> CArray.to_list;
      rom_base_addr = getf !@_t B.Pci_dev.rom_base_addr;
      rom_size = getf !@_t B.Pci_dev.rom_size;
      phy_slot = getf !@_t B.Pci_dev.phy_slot;
      subsystem_id =
        match (B.pci_read_byte _t T.Header.header_type |> U8.to_int) land 0x7f with
        | x when x = T.Header.header_type_normal ->
          Some (
            B.pci_read_word _t T.Header.subsystem_vendor_id |> U16.to_int,
            B.pci_read_word _t T.Header.subsystem_id |> U16.to_int)
        | x when x = T.Header.header_type_cardbus ->
          Some (
            B.pci_read_word _t T.Header.cb_subsystem_vendor_id |> U16.to_int,
            B.pci_read_word _t T.Header.cb_subsystem_id |> U16.to_int)
        | _ -> None
    }
end

module Pci_access = struct
  type t = B.Pci_access.t

  let devices t =
    let rec list_of_linked_list acc = function
    | None -> acc
    | Some d -> list_of_linked_list (d::acc) (getf !@d B.Pci_dev.next) in
    list_of_linked_list [] (getf !@t B.Pci_access.devices)
end

type fill_flag =
  | FILL_IDENT
  | FILL_IRQ
  | FILL_BASES
  | FILL_ROM_BASE
  | FILL_SIZES
  | FILL_CLASS
  | FILL_CAPS
  | FILL_EXT_CAPS
  | FILL_PHYS_SLOT
  | FILL_MODULE_ALIAS
  | FILL_RESCAN

let int_of_fill_flag = function
  | FILL_IDENT -> T.Fill_flag.fill_ident
  | FILL_IRQ -> T.Fill_flag.fill_irq
  | FILL_BASES -> T.Fill_flag.fill_bases
  | FILL_ROM_BASE -> T.Fill_flag.fill_rom_base
  | FILL_SIZES -> T.Fill_flag.fill_sizes
  | FILL_CLASS -> T.Fill_flag.fill_class
  | FILL_CAPS -> T.Fill_flag.fill_caps
  | FILL_EXT_CAPS -> T.Fill_flag.fill_ext_caps
  | FILL_PHYS_SLOT -> T.Fill_flag.fill_phys_slot
  | FILL_MODULE_ALIAS -> T.Fill_flag.fill_module_alias
  | FILL_RESCAN -> T.Fill_flag.fill_rescan

let crush_flags f =
  List.fold_left (fun i o -> i lor (f o)) 0
let id x = x

let scan_bus = B.pci_scan_bus

let fill_info d flag_list =
  B.pci_fill_info d @@ crush_flags int_of_fill_flag flag_list

let with_string ?(size=1024) f =
  let buf = Bytes.make size '\000' in
  f buf size

let lookup_class_name pci_access class_id =
  with_string (fun buf size ->
    B.pci_lookup_name_1_ary pci_access buf size T.Lookup_mode.lookup_class
      class_id)

let lookup_progif_name pci_access class_id progif_id =
  with_string (fun buf size ->
    B.pci_lookup_name_2_ary pci_access buf size T.Lookup_mode.lookup_progif
      class_id progif_id)

let lookup_vendor_name pci_access vendor_id =
  with_string (fun buf size ->
    B.pci_lookup_name_1_ary pci_access buf size T.Lookup_mode.lookup_vendor
      vendor_id)

let lookup_device_name pci_access vendor_id device_id =
  with_string (fun buf size ->
    B.pci_lookup_name_2_ary pci_access buf size T.Lookup_mode.lookup_device
      vendor_id device_id)

let lookup_subsystem_vendor_name pci_access subv_id =
  with_string (fun buf size ->
    let lookup_flags = T.Lookup_mode.([ lookup_subsystem; lookup_vendor ]) in
    B.pci_lookup_name_1_ary pci_access buf size (crush_flags id lookup_flags)
      subv_id)

let lookup_subsystem_device_name pci_access vendor_id device_id subv_id subd_id =
  with_string (fun buf size ->
    let lookup_flags = T.Lookup_mode.([ lookup_subsystem; lookup_device ]) in
    B.pci_lookup_name_4_ary pci_access buf size (crush_flags id lookup_flags)
      vendor_id device_id subv_id subd_id)

let with_access ?(cleanup=true) f =
  let pci_access = B.pci_alloc () in
  if not cleanup then f pci_access
  else
    let result =
      try
        B.pci_init pci_access;
        f pci_access
      with exn ->
        (try B.pci_cleanup pci_access with _ -> ());
        raise exn
    in
    B.pci_cleanup pci_access;
    result

let get_devices pci_access =
  B.pci_scan_bus pci_access;
  let devs = Pci_access.devices pci_access in
  (* Be sure to fill all the fields that can be accessed from a Pci_dev.t *)
  let all_fill_flags = [
    FILL_IDENT; FILL_IRQ; FILL_BASES; FILL_ROM_BASE; FILL_SIZES; FILL_CLASS;
    FILL_CAPS; FILL_EXT_CAPS; FILL_PHYS_SLOT; FILL_MODULE_ALIAS ] in
  let flags = crush_flags int_of_fill_flag all_fill_flags in
  List.map (fun d -> let (_: int) = B.pci_fill_info d flags in Pci_dev.make d) devs

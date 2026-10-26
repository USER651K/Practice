*&---------------------------------------------------------------------*
*& Report ZSCWM_WO_PICKSHEET_PRINT
*&---------------------------------------------------------------------*
*& Manual print / reprint of the EWM Warehouse Order Pick Sheet
*& (Smartform ZSCWM_WO_PICKSHEET) by Outbound Delivery and/or
*& Warehouse Order.
*&
*& - One form call per warehouse order (same as PPF action WO_MULTIPLE)
*& - Tasks passed exactly like PPF: all open tasks (ORDIM_O) and all
*&   confirmed tasks (ORDIM_C) of the WO; the form decides what to print
*& - All sheets are collected in ONE spool job (one print dialog)
*& - WOs for which the form raises NO_DATA (nothing to print, excluded
*&   by ZEWM_PWO_SPOOLALLOW / partial-pick rule, ZUKL exclusion) are
*&   skipped silently and counted
*&
*& Created: 26.10.2026 - Ujwal (BA-4030)
*&---------------------------------------------------------------------*
REPORT zscwm_wo_picksheet_print.

*----------------------------------------------------------------------*
* Constants
*----------------------------------------------------------------------*
CONSTANTS: gc_form TYPE tdsfname VALUE 'ZSCWM_WO_PICKSHEET'.

*----------------------------------------------------------------------*
* Types
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_who,
         who TYPE /scwm/ordim_o-who,
       END OF ty_who,
       BEGIN OF ty_docid,
         docid TYPE /scdl/db_proch_o-docid,
       END OF ty_docid.

*----------------------------------------------------------------------*
* Data
*----------------------------------------------------------------------*
DATA: gv_docno TYPE /scdl/db_proch_o-docno,       "for select-option
      gv_who   TYPE /scwm/ordim_o-who.            "for select-option

DATA: gt_who     TYPE STANDARD TABLE OF ty_who,
      gt_who_tmp TYPE STANDARD TABLE OF ty_who,
      gs_who     TYPE ty_who,
      gt_docid   TYPE STANDARD TABLE OF ty_docid,
      gt_ordim_o TYPE /scwm/tt_ordim_o,
      gt_ordim_c TYPE /scwm/tt_ordim_c.

DATA: gv_fm_name  TYPE rs38l_fnam,
      gs_ctrl     TYPE ssfctrlop,
      gs_outopt   TYPE ssfcompop,
      gs_job_out  TYPE ssfcrescl,
      gv_printed  TYPE i,
      gv_skipped  TYPE i,
      gv_errors   TYPE i,
      gv_job_open TYPE abap_bool.

*----------------------------------------------------------------------*
* Selection screen
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS:     p_lgnum TYPE /scwm/lgnum OBLIGATORY DEFAULT '3U01'.
  SELECT-OPTIONS: s_docno FOR gv_docno,
                  s_who   FOR gv_who.
SELECTION-SCREEN END OF BLOCK b1.

*----------------------------------------------------------------------*
* Validation: at least delivery or warehouse order
*----------------------------------------------------------------------*
AT SELECTION-SCREEN.
  IF sy-ucomm = 'ONLI' OR sy-ucomm = 'PRIN' OR sy-ucomm IS INITIAL.
    IF s_docno[] IS INITIAL AND s_who[] IS INITIAL.
      MESSAGE 'Enter an Outbound Delivery or a Warehouse Order'(e01)
        TYPE 'E'.
    ENDIF.
  ENDIF.

*----------------------------------------------------------------------*
* Main
*----------------------------------------------------------------------*
START-OF-SELECTION.

  PERFORM get_warehouse_orders.

  IF gt_who IS INITIAL.
    MESSAGE 'No warehouse orders found for the selection'(e02)
      TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  PERFORM get_form_fm.
  PERFORM print_pick_sheets.
  PERFORM show_result.

*&---------------------------------------------------------------------*
*& Form GET_WAREHOUSE_ORDERS
*&---------------------------------------------------------------------*
*& WOs from the delivery (via tasks referencing the delivery) and/or
*& entered directly. If both are entered, only WOs matching both.
*&---------------------------------------------------------------------*
FORM get_warehouse_orders.

  CLEAR: gt_who, gt_docid.

*--- WOs of the selected deliveries --------------------------------------
  IF s_docno[] IS NOT INITIAL.

    SELECT docid FROM /scdl/db_proch_o
      INTO TABLE gt_docid
      WHERE docno IN s_docno.

    IF gt_docid IS NOT INITIAL.
*     Open tasks
      SELECT who FROM /scwm/ordim_o
        INTO TABLE gt_who
        FOR ALL ENTRIES IN gt_docid
        WHERE lgnum  = p_lgnum
          AND rdocid = gt_docid-docid.

*     Confirmed tasks (reprint after confirmation)
      CLEAR gt_who_tmp.
      SELECT who FROM /scwm/ordim_c
        INTO TABLE gt_who_tmp
        FOR ALL ENTRIES IN gt_docid
        WHERE lgnum  = p_lgnum
          AND rdocid = gt_docid-docid.
      APPEND LINES OF gt_who_tmp TO gt_who.
    ENDIF.

    DELETE gt_who WHERE who IS INITIAL.

*   Both entered: keep only the entered WOs
    IF s_who[] IS NOT INITIAL.
      DELETE gt_who WHERE NOT who IN s_who.
    ENDIF.

*--- Only WOs entered ------------------------------------------------------
  ELSE.
    SELECT who FROM /scwm/ordim_o
      INTO TABLE gt_who
      WHERE lgnum = p_lgnum
        AND who  IN s_who.

    CLEAR gt_who_tmp.
    SELECT who FROM /scwm/ordim_c
      INTO TABLE gt_who_tmp
      WHERE lgnum = p_lgnum
        AND who  IN s_who.
    APPEND LINES OF gt_who_tmp TO gt_who.

    DELETE gt_who WHERE who IS INITIAL.
  ENDIF.

  SORT gt_who BY who.
  DELETE ADJACENT DUPLICATES FROM gt_who COMPARING who.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_FORM_FM
*&---------------------------------------------------------------------*
FORM get_form_fm.

  CALL FUNCTION 'SSF_FUNCTION_MODULE_NAME'
    EXPORTING
      formname           = gc_form
    IMPORTING
      fm_name            = gv_fm_name
    EXCEPTIONS
      no_form            = 1
      no_function_module = 2
      OTHERS             = 3.
  IF sy-subrc <> 0.
    MESSAGE 'Smartform ZSCWM_WO_PICKSHEET not found / not active'(e03)
      TYPE 'E'.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form PRINT_PICK_SHEETS
*&---------------------------------------------------------------------*
*& One spool job for all WOs: SSF_OPEN (print dialog once),
*& form call per WO with NO_OPEN/NO_CLOSE, SSF_CLOSE.
*&---------------------------------------------------------------------*
FORM print_pick_sheets.

  CLEAR: gs_ctrl, gs_outopt, gv_printed, gv_skipped, gv_errors,
         gv_job_open.

*--- Open job (print dialog: printer, preview, copies) --------------------
  gs_ctrl-no_dialog = abap_false.
  gs_ctrl-preview   = abap_false.

  CALL FUNCTION 'SSF_OPEN'
    EXPORTING
      control_parameters = gs_ctrl
      output_options     = gs_outopt
      user_settings      = abap_true
    EXCEPTIONS
      formatting_error   = 1
      internal_error     = 2
      send_error         = 3
      user_canceled      = 4
      OTHERS             = 5.
  IF sy-subrc = 4.
    MESSAGE 'Printing cancelled'(i01) TYPE 'S'.
    RETURN.
  ELSEIF sy-subrc <> 0.
    MESSAGE 'Error opening the print job'(e04) TYPE 'E'.
  ENDIF.
  gv_job_open = abap_true.

*--- Form call per warehouse order ------------------------------------------
  gs_ctrl-no_open   = abap_true.
  gs_ctrl-no_close  = abap_true.
  gs_ctrl-no_dialog = abap_true.

  LOOP AT gt_who INTO gs_who.

    CLEAR: gt_ordim_o, gt_ordim_c.

*   All tasks of the WO - same input as PPF action WO_MULTIPLE
    SELECT * FROM /scwm/ordim_o
      INTO TABLE gt_ordim_o
      WHERE lgnum = p_lgnum
        AND who   = gs_who-who.

    SELECT * FROM /scwm/ordim_c
      INTO TABLE gt_ordim_c
      WHERE lgnum = p_lgnum
        AND who   = gs_who-who.

    IF gt_ordim_o IS INITIAL AND gt_ordim_c IS INITIAL.
      gv_skipped = gv_skipped + 1.
      CONTINUE.
    ENDIF.

    CALL FUNCTION gv_fm_name
      EXPORTING
        control_parameters = gs_ctrl
        user_settings      = abap_false
        ordim_o            = gt_ordim_o
        ordim_c            = gt_ordim_c
      EXCEPTIONS
        formatting_error   = 1
        internal_error     = 2
        send_error         = 3
        user_canceled      = 4
        no_data            = 5
        OTHERS             = 6.

    CASE sy-subrc.
      WHEN 0.
        gv_printed = gv_printed + 1.
      WHEN 5.
*       Nothing to print for this WO (form decided) - skip silently
        gv_skipped = gv_skipped + 1.
      WHEN OTHERS.
        gv_errors = gv_errors + 1.
    ENDCASE.

  ENDLOOP.

*--- Close job ----------------------------------------------------------------
  CALL FUNCTION 'SSF_CLOSE'
    IMPORTING
      job_output_info  = gs_job_out
    EXCEPTIONS
      formatting_error = 1
      internal_error   = 2
      send_error       = 3
      OTHERS           = 4.
  IF sy-subrc <> 0.
    gv_errors = gv_errors + 1.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form SHOW_RESULT
*&---------------------------------------------------------------------*
FORM show_result.

  DATA lv_msg TYPE string.

  IF gv_job_open = abap_false.
    RETURN.
  ENDIF.

  lv_msg = |Pick sheets printed: { gv_printed }, | &&
           |skipped (nothing to print): { gv_skipped }, | &&
           |errors: { gv_errors }|.

  IF gv_errors > 0.
    MESSAGE lv_msg TYPE 'S' DISPLAY LIKE 'W'.
  ELSEIF gv_printed = 0.
    MESSAGE lv_msg TYPE 'S' DISPLAY LIKE 'E'.
  ELSE.
    MESSAGE lv_msg TYPE 'S'.
  ENDIF.

ENDFORM.

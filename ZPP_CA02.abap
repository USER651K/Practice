*&---------------------------------------------------------------------*
*& Report ZPP_CA02
*&---------------------------------------------------------------------*
*& Title       : Change Routing: Add Operations
*& TCode       : ZPP_CA02
*& FS          : FS - Routing Operation Addition (ZPP_CA02)
*& Description : Adds Sortex operations to existing Routings (task list
*&               type N) from an Excel file using FM ROUTING_MAINTAIN.
*&               All Excel lines are validated first; the FM is called
*&               only if the whole file is free of errors.
*&---------------------------------------------------------------------*
REPORT zpp_ca02.

*----------------------------------------------------------------------*
* Types
*----------------------------------------------------------------------*
TYPES: BEGIN OF ty_raw,
         line TYPE i,                        " Data line no. (Excel row - 1)
         c1   TYPE string,                   " Routing Group
         c2   TYPE string,                   " Group Counter
         c3   TYPE string,                   " Work Center
         c4   TYPE string,                   " Control Key
         c5   TYPE string,                   " Operation Description
         c6   TYPE string,                   " Operation Base Quantity
         c7   TYPE string,                   " Operation Base Quantity Unit
         c8   TYPE string,                   " Machining Hours
       END OF ty_raw.

TYPES: BEGIN OF ty_excel,
         line  TYPE i,
         plnnr TYPE plas-plnnr,
         plnal TYPE plas-plnal,
         arbpl TYPE crhd-arbpl,
         steus TYPE plpo-steus,
         ltxa1 TYPE plpo-ltxa1,
         bmsch TYPE plpo-bmsch,
         meinh TYPE plpo-meinh,
         vgw01 TYPE plpo-vgw01,
         werks TYPE plko-werks,              " Derived from PLKO
         plnme TYPE plko-plnme,              " Derived from PLKO
       END OF ty_excel.

TYPES: BEGIN OF ty_log,
         srno    TYPE i,
         line    TYPE i,
         remarks TYPE string,
         t_color TYPE lvc_t_scol,            " Technical - not displayed
       END OF ty_log.

TYPES: BEGIN OF ty_vornr,
         plnnr TYPE plas-plnnr,
         plnal TYPE plas-plnal,
         vornr TYPE i,
       END OF ty_vornr.

TYPES: BEGIN OF ty_fmpar,
         parameter TYPE fupararef-parameter,
         paramtype TYPE fupararef-paramtype,
         structure TYPE fupararef-structure,
       END OF ty_fmpar.

TYPES: BEGIN OF ty_fmout,
         name TYPE abap_parmname,
         ref  TYPE REF TO data,
       END OF ty_fmout.

*----------------------------------------------------------------------*
* Data
*----------------------------------------------------------------------*
DATA: gt_raw    TYPE STANDARD TABLE OF ty_raw,
      gs_raw    TYPE ty_raw,
      gt_excel  TYPE STANDARD TABLE OF ty_excel,
      gs_excel  TYPE ty_excel,
      gt_log    TYPE STANDARD TABLE OF ty_log,
      gs_log    TYPE ty_log,
      gt_intern TYPE STANDARD TABLE OF alsmex_tabline,
      gs_intern TYPE alsmex_tabline,
      gt_vornr  TYPE HASHED TABLE OF ty_vornr WITH UNIQUE KEY plnnr plnal,
      gt_fmpar  TYPE STANDARD TABLE OF ty_fmpar.

DATA: go_alv     TYPE REF TO cl_salv_table,
      go_funcs   TYPE REF TO cl_salv_functions_list,
      go_columns TYPE REF TO cl_salv_columns_table,
      go_column  TYPE REF TO cl_salv_column,
      go_display TYPE REF TO cl_salv_display_settings,
      go_layout  TYPE REF TO cl_salv_layout,
      gs_lkey    TYPE salv_s_layout_key.

DATA: gv_errors_found TYPE abap_bool,
      gv_srno         TYPE i.

*----------------------------------------------------------------------*
* Constants
*----------------------------------------------------------------------*
CONSTANTS: gc_max_path_len TYPE i                VALUE 128,
           gc_plnty_n      TYPE plas-plnty       VALUE 'N',
           gc_objty_wc     TYPE crhd-objty       VALUE 'A',
           gc_fm_name      TYPE rs38l_fnam       VALUE 'ROUTING_MAINTAIN',
           gc_par_opr      TYPE abap_parmname    VALUE 'OPERATIONS',
           gc_par_oprx     TYPE abap_parmname    VALUE 'OPERATIONS_X',
           gc_vornr_step   TYPE i                VALUE 10,
           gc_vornr_max    TYPE i                VALUE 9999,
           gc_col_red      TYPE lvc_col          VALUE 6,
           gc_col_green    TYPE lvc_col          VALUE 5.

*----------------------------------------------------------------------*
* Selection Screen
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS: p_file TYPE localfile OBLIGATORY.
SELECTION-SCREEN END OF BLOCK b1.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  PERFORM f4_file_help CHANGING p_file.

AT SELECTION-SCREEN.
  PERFORM validate_file.

START-OF-SELECTION.

  IF sy-batch = abap_true.
    MESSAGE 'This program can be executed in foreground only.' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  PERFORM read_excel_file.

  IF gt_excel IS INITIAL.
    MESSAGE 'The Input File is Blank.' TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  PERFORM validate_data.

  IF gv_errors_found = abap_false.
    PERFORM post_routing_operations.
  ENDIF.

  PERFORM display_log_alv.

*&---------------------------------------------------------------------*
*& Form F4_FILE_HELP
*&---------------------------------------------------------------------*
FORM f4_file_help CHANGING cv_file TYPE localfile.

  DATA: lt_files  TYPE filetable,
        ls_file   TYPE file_table,
        lv_rc     TYPE i,
        lv_action TYPE i.

  cl_gui_frontend_services=>file_open_dialog(
    EXPORTING
      window_title            = 'Select Input Excel File'
      default_extension       = 'XLSX'
      file_filter             = 'Excel Files (*.XLSX;*.XLS)|*.XLSX;*.XLS|All Files (*.*)|*.*'
    CHANGING
      file_table              = lt_files
      rc                      = lv_rc
      user_action             = lv_action
    EXCEPTIONS
      file_open_dialog_failed = 1
      cntl_error              = 2
      error_no_gui            = 3
      not_supported_by_gui    = 4
      OTHERS                  = 5 ).

  IF sy-subrc = 0
    AND lv_action = cl_gui_frontend_services=>action_ok.
    READ TABLE lt_files INTO ls_file INDEX 1.
    IF sy-subrc = 0.
*     Path longer than P_FILE can hold would be truncated silently
      IF strlen( ls_file-filename ) > gc_max_path_len.
        MESSAGE 'The Input File Path is too Long.' TYPE 'S' DISPLAY LIKE 'E'.
      ELSE.
        cv_file = ls_file-filename.
      ENDIF.
    ENDIF.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form VALIDATE_FILE
*&---------------------------------------------------------------------*
FORM validate_file.

  DATA: lv_filename TYPE string,
        lv_ext      TYPE string,
        lv_offset   TYPE i,
        lv_exist    TYPE abap_bool.

  lv_filename = p_file.

* Validation - Path too long (field full = path was cut at 128 chars)
  IF strlen( lv_filename ) >= gc_max_path_len.
    MESSAGE 'The Input File Path is too Long.' TYPE 'E'.
  ENDIF.

* Validation - File format must be Excel
  FIND ALL OCCURRENCES OF '.' IN lv_filename MATCH OFFSET lv_offset.
  IF sy-subrc = 0.
    lv_ext = lv_filename+lv_offset.
    TRANSLATE lv_ext TO UPPER CASE.
    IF lv_ext <> '.XLSX' AND lv_ext <> '.XLS'.
      MESSAGE 'The Input File Format is not Excel.' TYPE 'E'.
    ENDIF.
  ELSE.
    MESSAGE 'The Input File Format is not Excel.' TYPE 'E'.
  ENDIF.

* Validation - File must exist on the front end
  cl_gui_frontend_services=>file_exist(
    EXPORTING
      file                 = lv_filename
    RECEIVING
      result               = lv_exist
    EXCEPTIONS
      cntl_error           = 1
      error_no_gui         = 2
      wrong_parameter      = 3
      not_supported_by_gui = 4
      OTHERS               = 5 ).
  IF sy-subrc = 0 AND lv_exist = abap_false.
    MESSAGE 'The Input File does not exist.' TYPE 'E'.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form READ_EXCEL_FILE
*&---------------------------------------------------------------------*
FORM read_excel_file.

  DATA: lv_filename TYPE rlgrap-filename.

  CLEAR: gt_intern, gt_raw, gt_excel.

  lv_filename = p_file.

  CALL FUNCTION 'ALSM_EXCEL_TO_INTERNAL_TABLE'
    EXPORTING
      filename                = lv_filename
      i_begin_col             = 1
      i_begin_row             = 2          " Row 1 = header
      i_end_col               = 8
      i_end_row               = 9999       " ALSM row field is NUMC 4
    TABLES
      intern                  = gt_intern
    EXCEPTIONS
      inconsistent_parameters = 1
      upload_ole              = 2
      OTHERS                  = 3.

  IF sy-subrc = 2.
    MESSAGE 'The Input File could not be read. Close the file in Excel and try again.'
      TYPE 'S' DISPLAY LIKE 'E'.
    LEAVE LIST-PROCESSING.
  ELSEIF sy-subrc <> 0.
    MESSAGE 'The Input File is Blank.' TYPE 'S' DISPLAY LIKE 'E'.
    LEAVE LIST-PROCESSING.
  ENDIF.

  IF gt_intern IS INITIAL.
    RETURN.
  ENDIF.

  SORT gt_intern BY row col.

  LOOP AT gt_intern INTO gs_intern.

    AT NEW row.
      CLEAR gs_raw.
    ENDAT.

*   ALSM row is relative to I_BEGIN_ROW => row 1 = first data line
    gs_raw-line = gs_intern-row.

    CASE gs_intern-col.
      WHEN 1. gs_raw-c1 = gs_intern-value.
      WHEN 2. gs_raw-c2 = gs_intern-value.
      WHEN 3. gs_raw-c3 = gs_intern-value.
      WHEN 4. gs_raw-c4 = gs_intern-value.
      WHEN 5. gs_raw-c5 = gs_intern-value.
      WHEN 6. gs_raw-c6 = gs_intern-value.
      WHEN 7. gs_raw-c7 = gs_intern-value.
      WHEN 8. gs_raw-c8 = gs_intern-value.
    ENDCASE.

    AT END OF row.
*     Skip rows that contain only spaces
      IF gs_raw-c1 IS NOT INITIAL OR gs_raw-c2 IS NOT INITIAL
      OR gs_raw-c3 IS NOT INITIAL OR gs_raw-c4 IS NOT INITIAL
      OR gs_raw-c5 IS NOT INITIAL OR gs_raw-c6 IS NOT INITIAL
      OR gs_raw-c7 IS NOT INITIAL OR gs_raw-c8 IS NOT INITIAL.
        APPEND gs_raw TO gt_raw.
      ENDIF.
    ENDAT.

  ENDLOOP.

  PERFORM convert_raw_to_typed.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form CONVERT_RAW_TO_TYPED
*&---------------------------------------------------------------------*
FORM convert_raw_to_typed.

  DATA: lv_plnnr TYPE plas-plnnr,
        lv_plnal TYPE plas-plnal,
        lv_unit  TYPE c LENGTH 3.

  LOOP AT gt_raw INTO gs_raw.

    CLEAR gs_excel.
    gs_excel-line = gs_raw-line.

*   Normalise raw values (normalised values are also used by validations)
    CONDENSE: gs_raw-c1 NO-GAPS, gs_raw-c2 NO-GAPS, gs_raw-c3 NO-GAPS,
              gs_raw-c4 NO-GAPS, gs_raw-c6 NO-GAPS, gs_raw-c7 NO-GAPS,
              gs_raw-c8 NO-GAPS.
    SHIFT gs_raw-c5 LEFT DELETING LEADING space.
    TRANSLATE: gs_raw-c1 TO UPPER CASE, gs_raw-c2 TO UPPER CASE,
               gs_raw-c3 TO UPPER CASE, gs_raw-c4 TO UPPER CASE,
               gs_raw-c7 TO UPPER CASE.
*   Comma is treated as thousand separator, '.' as decimal separator
    REPLACE ALL OCCURRENCES OF ',' IN gs_raw-c6 WITH ''.
    REPLACE ALL OCCURRENCES OF ',' IN gs_raw-c8 WITH ''.
    MODIFY gt_raw FROM gs_raw.

*   Routing Group - internal format
    IF gs_raw-c1 IS NOT INITIAL AND strlen( gs_raw-c1 ) <= 8.
      lv_plnnr = gs_raw-c1.
      CALL FUNCTION 'CONVERSION_EXIT_ALPHA_INPUT'
        EXPORTING
          input  = lv_plnnr
        IMPORTING
          output = gs_excel-plnnr.
    ENDIF.

*   Group Counter - '1' => '01'
    IF gs_raw-c2 IS NOT INITIAL AND strlen( gs_raw-c2 ) <= 2.
      lv_plnal = gs_raw-c2.
      CALL FUNCTION 'CONVERSION_EXIT_ALPHA_INPUT'
        EXPORTING
          input  = lv_plnal
        IMPORTING
          output = gs_excel-plnal.
    ENDIF.

*   Work Center
    IF strlen( gs_raw-c3 ) <= 8.
      gs_excel-arbpl = gs_raw-c3.
    ENDIF.

*   Control Key
    IF strlen( gs_raw-c4 ) <= 4.
      gs_excel-steus = gs_raw-c4.
    ENDIF.

*   Operation Description (length validated on raw value)
    gs_excel-ltxa1 = gs_raw-c5.

*   Operation Base Quantity
    IF gs_raw-c6 IS NOT INITIAL.
      TRY.
          gs_excel-bmsch = gs_raw-c6.
        CATCH cx_sy_conversion_error cx_sy_arithmetic_error.
          CLEAR gs_excel-bmsch.
      ENDTRY.
    ENDIF.

*   Operation Base Quantity Unit - external => internal
    IF gs_raw-c7 IS NOT INITIAL AND strlen( gs_raw-c7 ) <= 3.
      lv_unit = gs_raw-c7.
      CALL FUNCTION 'CONVERSION_EXIT_CUNIT_INPUT'
        EXPORTING
          input          = lv_unit
          language       = sy-langu
        IMPORTING
          output         = gs_excel-meinh
        EXCEPTIONS
          unit_not_found = 1
          OTHERS         = 2.
      IF sy-subrc <> 0.
        gs_excel-meinh = lv_unit.
      ENDIF.
    ENDIF.

*   Machining Hours
    IF gs_raw-c8 IS NOT INITIAL.
      TRY.
          gs_excel-vgw01 = gs_raw-c8.
        CATCH cx_sy_conversion_error cx_sy_arithmetic_error.
          CLEAR gs_excel-vgw01.
      ENDTRY.
    ENDIF.

    APPEND gs_excel TO gt_excel.

  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form VALIDATE_DATA
*&---------------------------------------------------------------------*
FORM validate_data.

  DATA: lv_tabix   TYPE sy-tabix,
        lv_line    TYPE i,
        lv_str     TYPE string,
        lv_rtg_ok  TYPE abap_bool,
        lv_grp_ok  TYPE abap_bool,
        lv_hdr_ok  TYPE abap_bool,
        lv_found   TYPE abap_bool,
        lv_plnnr   TYPE plas-plnnr,
        lv_plnal   TYPE plas-plnal,
        lv_arbpl   TYPE crhd-arbpl,
        lv_steus   TYPE t430-steus,
        lv_unit_tl TYPE t006a-mseh3.

  CLEAR: gv_srno, gv_errors_found, gt_log.

  LOOP AT gt_excel INTO gs_excel.

    lv_tabix = sy-tabix.
    lv_line  = gs_excel-line.
    CLEAR: lv_rtg_ok, lv_grp_ok, lv_hdr_ok.

    READ TABLE gt_raw INTO gs_raw INDEX lv_tabix.

*----------------------------------------------------------------------*
* Validation 1: Blank Routing Group
*----------------------------------------------------------------------*
    IF gs_raw-c1 IS INITIAL.
      PERFORM add_log USING lv_line 'Routing Group cannot be Blank.' 'E'.
    ELSE.
*----------------------------------------------------------------------*
* Validation 2: Invalid Routing Group (PLPO, PLNTY = N)
*----------------------------------------------------------------------*
      IF gs_excel-plnnr IS NOT INITIAL.
        SELECT SINGLE plnnr FROM plpo INTO lv_plnnr
          WHERE plnty = gc_plnty_n
            AND plnnr = gs_excel-plnnr.
        IF sy-subrc = 0.
          lv_rtg_ok = abap_true.
        ENDIF.
      ENDIF.
      IF lv_rtg_ok = abap_false.
        lv_str = |Routing Group { gs_raw-c1 } does not exists.|.
        PERFORM add_log USING lv_line lv_str 'E'.
      ENDIF.
    ENDIF.

*----------------------------------------------------------------------*
* Validation 3: Blank Group Counter
*----------------------------------------------------------------------*
    IF gs_raw-c2 IS INITIAL.
      PERFORM add_log USING lv_line 'Group Counter cannot be Blank.' 'E'.
    ELSEIF lv_rtg_ok = abap_true.
*----------------------------------------------------------------------*
* Validation 4: Invalid Group Counter (PLAS)
*----------------------------------------------------------------------*
      IF gs_excel-plnal IS NOT INITIAL.
        SELECT SINGLE plnal FROM plas INTO lv_plnal
          WHERE plnty = gc_plnty_n
            AND plnnr = gs_excel-plnnr
            AND plnal = gs_excel-plnal
            AND loekz = space.
        IF sy-subrc = 0.
          lv_grp_ok = abap_true.
        ENDIF.
      ENDIF.
      IF lv_grp_ok = abap_false.
        lv_str = |Group Counter { gs_raw-c2 } is not created for Routing Group { gs_raw-c1 }.|.
        PERFORM add_log USING lv_line lv_str 'E'.
      ENDIF.
    ENDIF.

*----------------------------------------------------------------------*
* PLKO - Plant and Task List Unit (latest, not deleted)
*----------------------------------------------------------------------*
    IF lv_grp_ok = abap_true.
      SELECT werks plnme FROM plko
        INTO (gs_excel-werks, gs_excel-plnme)
        UP TO 1 ROWS
        WHERE plnty = gc_plnty_n
          AND plnnr = gs_excel-plnnr
          AND plnal = gs_excel-plnal
          AND loekz = space
        ORDER BY zaehl DESCENDING.
      ENDSELECT.
      IF sy-subrc = 0.
        lv_hdr_ok = abap_true.
      ELSE.
        lv_str = |Header data not found for Routing Group { gs_raw-c1 }, Group Counter { gs_raw-c2 }.|.
        PERFORM add_log USING lv_line lv_str 'E'.
      ENDIF.
    ENDIF.

*----------------------------------------------------------------------*
* Validation 5: Blank Work Center
*----------------------------------------------------------------------*
    IF gs_raw-c3 IS INITIAL.
      PERFORM add_log USING lv_line 'Work Center cannot be Blank.' 'E'.
    ELSEIF lv_hdr_ok = abap_true.
*----------------------------------------------------------------------*
* Validation 6: Invalid Work Center (CRHD with PLKO-WERKS)
*----------------------------------------------------------------------*
      lv_found = abap_false.
      IF gs_excel-arbpl IS NOT INITIAL.
        SELECT SINGLE arbpl FROM crhd INTO lv_arbpl
          WHERE objty = gc_objty_wc
            AND arbpl = gs_excel-arbpl
            AND werks = gs_excel-werks
            AND lvorm = space.
        IF sy-subrc = 0.
          lv_found = abap_true.
        ENDIF.
      ENDIF.
      IF lv_found = abap_false.
        lv_str = |Work Center { gs_raw-c3 } does not exist in Plant { gs_excel-werks }.|.
        PERFORM add_log USING lv_line lv_str 'E'.
      ENDIF.
    ENDIF.

*----------------------------------------------------------------------*
* Validation 7: Blank Control Key
*----------------------------------------------------------------------*
    IF gs_raw-c4 IS INITIAL.
      PERFORM add_log USING lv_line 'Control Key cannot be Blank.' 'E'.
    ELSE.
*----------------------------------------------------------------------*
* Validation 8: Invalid Control Key (T430)
*----------------------------------------------------------------------*
      lv_found = abap_false.
      IF gs_excel-steus IS NOT INITIAL.
        SELECT SINGLE steus FROM t430 INTO lv_steus
          WHERE steus = gs_excel-steus.
        IF sy-subrc = 0.
          lv_found = abap_true.
        ENDIF.
      ENDIF.
      IF lv_found = abap_false.
        PERFORM add_log USING lv_line 'Control Key is invalid.' 'E'.
      ENDIF.
    ENDIF.

*----------------------------------------------------------------------*
* Validation 9: Blank Operation Description
*----------------------------------------------------------------------*
    IF gs_raw-c5 IS INITIAL.
      PERFORM add_log USING lv_line 'Operation Description cannot be Blank.' 'E'.
*----------------------------------------------------------------------*
* Validation 10: Operation Description longer than 40 characters
*----------------------------------------------------------------------*
    ELSEIF strlen( gs_raw-c5 ) > 40.
      PERFORM add_log USING lv_line
        'Operation Description cannot be more than 40 Characters.' 'E'.
    ENDIF.

*----------------------------------------------------------------------*
* Validation 11: Blank Operation Base Quantity
*----------------------------------------------------------------------*
    IF gs_raw-c6 IS INITIAL.
      PERFORM add_log USING lv_line 'Operation Base Quantity cannot be Blank.' 'E'.
    ELSE.
*----------------------------------------------------------------------*
* Validation 12: Invalid Operation Base Quantity (PLPO-BMSCH: 13,3, > 0)
*----------------------------------------------------------------------*
      FIND REGEX '^\d{1,10}(\.\d{1,3})?$' IN gs_raw-c6.
      IF sy-subrc <> 0 OR gs_excel-bmsch <= 0.
        PERFORM add_log USING lv_line 'Operation Base Quantity is invalid.' 'E'.
      ENDIF.
    ENDIF.

*----------------------------------------------------------------------*
* Validation 13: Blank Operation Base Quantity Unit
*----------------------------------------------------------------------*
    IF gs_raw-c7 IS INITIAL.
      PERFORM add_log USING lv_line 'Operation Base Quantity Unit cannot be Blank.' 'E'.
    ELSEIF lv_hdr_ok = abap_true.
*----------------------------------------------------------------------*
* Validation 14: Unit must be same as Task List Unit (PLKO-PLNME)
*----------------------------------------------------------------------*
      IF gs_excel-meinh <> gs_excel-plnme.
        CALL FUNCTION 'CONVERSION_EXIT_CUNIT_OUTPUT'
          EXPORTING
            input          = gs_excel-plnme
            language       = sy-langu
          IMPORTING
            output         = lv_unit_tl
          EXCEPTIONS
            unit_not_found = 1
            OTHERS         = 2.
        IF sy-subrc <> 0.
          lv_unit_tl = gs_excel-plnme.
        ENDIF.
        lv_str = |Operation Base Quantity Unit { gs_raw-c7 } should be same as Task List Unit { lv_unit_tl }.|.
        PERFORM add_log USING lv_line lv_str 'E'.
      ENDIF.
    ENDIF.

*----------------------------------------------------------------------*
* Validation 15: Blank Machining Hours
*----------------------------------------------------------------------*
    IF gs_raw-c8 IS INITIAL.
      PERFORM add_log USING lv_line 'Machining Hours cannot be Blank.' 'E'.
    ELSE.
*----------------------------------------------------------------------*
* Validation 16: Machining Hours - quantity with up to two decimals
*----------------------------------------------------------------------*
      FIND REGEX '^\d{1,6}(\.\d{1,2})?$' IN gs_raw-c8.
      IF sy-subrc <> 0.
        PERFORM add_log USING lv_line
          'Machining Hours value should be entered as Quantity with two decimal places.' 'E'.
      ENDIF.
    ENDIF.

*   Keep derived PLKO values for posting
    MODIFY gt_excel FROM gs_excel INDEX lv_tabix TRANSPORTING werks plnme.

  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form ADD_LOG
*&---------------------------------------------------------------------*
FORM add_log USING iv_line    TYPE i
                   iv_remarks TYPE csequence
                   iv_type    TYPE c.

  DATA: ls_color TYPE lvc_s_scol.

  ADD 1 TO gv_srno.
  CLEAR gs_log.
  gs_log-srno    = gv_srno.
  gs_log-line    = iv_line.
  gs_log-remarks = iv_remarks.

  ls_color-fname     = 'REMARKS'.
  ls_color-color-int = 0.
  ls_color-color-inv = 0.
  IF iv_type = 'E'.
    ls_color-color-col = gc_col_red.
    gv_errors_found    = abap_true.
  ELSE.
    ls_color-color-col = gc_col_green.
  ENDIF.
  APPEND ls_color TO gs_log-t_color.

  APPEND gs_log TO gt_log.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form POST_ROUTING_OPERATIONS
*&---------------------------------------------------------------------*
FORM post_routing_operations.

  DATA: lv_vornr_i TYPE i,
        lv_vornr   TYPE plpo-vornr,
        lv_chk     TYPE plpo-vornr,
        lv_iso     TYPE t006-isocode,
        lv_error   TYPE abap_bool,
        lv_success TYPE string,
        lt_err     TYPE string_table,
        lv_err     TYPE string,
        lv_str     TYPE string,
        ls_ret     TYPE bapiret2,
        ls_vornr   TYPE ty_vornr.

  PERFORM load_fm_interface CHANGING lv_error lv_str.
  IF lv_error = abap_true.
    PERFORM add_log USING 0 lv_str 'E'.
    RETURN.
  ENDIF.

  LOOP AT gt_excel INTO gs_excel.

    CLEAR: lv_error, lv_success, lt_err, lv_iso, lv_vornr, lv_str, ls_ret.

*   New Activity = highest existing VORNR + 10
    PERFORM get_next_vornr USING gs_excel
                           CHANGING lv_vornr_i lv_error lv_str.
    IF lv_error = abap_true.
      PERFORM add_log USING gs_excel-line lv_str 'E'.
      CONTINUE.
    ENDIF.
    lv_vornr = |{ lv_vornr_i WIDTH = 4 ALIGN = RIGHT PAD = '0' }|.

*   ISO code of the unit
    SELECT SINGLE isocode FROM t006 INTO lv_iso
      WHERE msehi = gs_excel-meinh.

    PERFORM call_routing_maintain USING gs_excel lv_vornr lv_iso
                                  CHANGING lv_error lv_success lt_err.

    IF lv_error = abap_true.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      IF lt_err IS INITIAL.
        lv_str = |Operation { lv_vornr } could not be added to Routing Group { gs_excel-plnnr ALPHA = OUT }, Group Counter { gs_excel-plnal }.|.
        APPEND lv_str TO lt_err.
      ENDIF.
      LOOP AT lt_err INTO lv_err.
        PERFORM add_log USING gs_excel-line lv_err 'E'.
      ENDLOOP.
      CONTINUE.
    ENDIF.

    CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'
      EXPORTING
        wait   = abap_true
      IMPORTING
        return = ls_ret.
    IF ls_ret-type CA 'EA'.
      lv_str = ls_ret-message.
      PERFORM add_log USING gs_excel-line lv_str 'E'.
      CONTINUE.
    ENDIF.

*   Confirm that the operation really exists after the commit
    SELECT SINGLE p~vornr INTO lv_chk
      FROM plas AS a INNER JOIN plpo AS p
        ON  p~plnty = a~plnty
        AND p~plnnr = a~plnnr
        AND p~plnkn = a~plnkn
      WHERE a~plnty = gc_plnty_n
        AND a~plnnr = gs_excel-plnnr
        AND a~plnal = gs_excel-plnal
        AND a~loekz = space
        AND p~vornr = lv_vornr.
    IF sy-subrc <> 0.
      lv_str = |No error returned, but Operation { lv_vornr } was not found in Routing Group { gs_excel-plnnr ALPHA = OUT }, Group Counter { gs_excel-plnal }.|.
      PERFORM add_log USING gs_excel-line lv_str 'E'.
      CONTINUE.
    ENDIF.

*   Remember last VORNR for further lines of the same routing/counter
    ls_vornr-plnnr = gs_excel-plnnr.
    ls_vornr-plnal = gs_excel-plnal.
    ls_vornr-vornr = lv_vornr_i.
    MODIFY TABLE gt_vornr FROM ls_vornr.
    IF sy-subrc <> 0.
      INSERT ls_vornr INTO TABLE gt_vornr.
    ENDIF.

    IF lv_success IS INITIAL.
      lv_success = |Task list (type N, group { gs_excel-plnnr ALPHA = OUT }, counter { gs_excel-plnal }) successfully changed.|.
    ENDIF.
    PERFORM add_log USING gs_excel-line lv_success 'S'.

  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_NEXT_VORNR
*&---------------------------------------------------------------------*
FORM get_next_vornr USING    is_excel TYPE ty_excel
                    CHANGING cv_vornr TYPE i
                             cv_error TYPE abap_bool
                             cv_text  TYPE string.

  DATA: lt_vornr TYPE STANDARD TABLE OF plpo-vornr,
        lv_vornr TYPE plpo-vornr,
        lv_num   TYPE i,
        lv_max   TYPE i,
        ls_track TYPE ty_vornr.

  CLEAR: cv_vornr, cv_error, cv_text.

* PLAS (PLNNR, PLNAL, PLNTY = N) => PLNKN => PLPO-VORNR
  SELECT p~vornr INTO TABLE lt_vornr
    FROM plas AS a INNER JOIN plpo AS p
      ON  p~plnty = a~plnty
      AND p~plnnr = a~plnnr
      AND p~plnkn = a~plnkn
    WHERE a~plnty = gc_plnty_n
      AND a~plnnr = is_excel-plnnr
      AND a~plnal = is_excel-plnal
      AND a~loekz = space
      AND p~loekz = space
      AND p~sumnr = '00000000'.        " Operations only, no sub-operations

  LOOP AT lt_vornr INTO lv_vornr.
    IF lv_vornr IS NOT INITIAL AND lv_vornr CO '0123456789 '.
      lv_num = lv_vornr.
      IF lv_num > lv_max.
        lv_max = lv_num.
      ENDIF.
    ENDIF.
  ENDLOOP.

* Operation already added by an earlier line of this file
  READ TABLE gt_vornr INTO ls_track
    WITH TABLE KEY plnnr = is_excel-plnnr
                   plnal = is_excel-plnal.
  IF sy-subrc = 0 AND ls_track-vornr > lv_max.
    lv_max = ls_track-vornr.
  ENDIF.

  cv_vornr = lv_max + gc_vornr_step.

  IF cv_vornr > gc_vornr_max.
    cv_error = abap_true.
    cv_text  = |New Operation number exceeds 9999 for Routing Group { is_excel-plnnr ALPHA = OUT }, Group Counter { is_excel-plnal }.|.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form LOAD_FM_INTERFACE
*&---------------------------------------------------------------------*
FORM load_fm_interface CHANGING cv_error TYPE abap_bool
                                cv_text  TYPE string.

  DATA: lt_req TYPE STANDARD TABLE OF abap_parmname,
        lv_req TYPE abap_parmname.

  CLEAR: cv_error, cv_text, gt_fmpar.

  SELECT parameter paramtype structure
    FROM fupararef
    INTO TABLE gt_fmpar
    WHERE funcname = gc_fm_name
      AND r3state  = 'A'.
  IF sy-subrc <> 0.
    cv_error = abap_true.
    cv_text  = |Function Module { gc_fm_name } is not available in the system.|.
    RETURN.
  ENDIF.

  APPEND 'KEY_DATE'        TO lt_req.
  APPEND 'TASK_LIST_GROUP' TO lt_req.
  APPEND 'GROUP_COUNTER'   TO lt_req.
  APPEND gc_par_opr        TO lt_req.
  APPEND gc_par_oprx       TO lt_req.

  LOOP AT lt_req INTO lv_req.
    READ TABLE gt_fmpar TRANSPORTING NO FIELDS WITH KEY parameter = lv_req.
    IF sy-subrc <> 0.
      cv_error = abap_true.
      cv_text  = |Parameter { lv_req } not found in Function Module { gc_fm_name }.|.
      RETURN.
    ENDIF.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form CALL_ROUTING_MAINTAIN
*&---------------------------------------------------------------------*
FORM call_routing_maintain USING    is_excel   TYPE ty_excel
                                    iv_vornr   TYPE plpo-vornr
                                    iv_iso     TYPE t006-isocode
                           CHANGING cv_error   TYPE abap_bool
                                    cv_success TYPE string
                                    ct_err     TYPE string_table.

  DATA: lt_ptab     TYPE abap_func_parmbind_tab,
        ls_pbind    TYPE abap_func_parmbind,
        lt_etab     TYPE abap_func_excpbind_tab,
        ls_ebind    TYPE abap_func_excpbind,
        lt_out      TYPE STANDARD TABLE OF ty_fmout,
        ls_out      TYPE ty_fmout,
        ls_fmpar    TYPE ty_fmpar,
        lr_opr      TYPE REF TO data,
        lr_oprx     TYPE REF TO data,
        lr_line     TYPE REF TO data,
        lr_linex    TYPE REF TO data,
        lv_kind     TYPE i,
        lv_kindx    TYPE i,
        lv_fail     TYPE abap_bool,
        lv_failx    TYPE abap_bool,
        lv_missing  TYPE string,
        lv_subrc    TYPE sy-subrc,
        lv_text     TYPE string,
        lv_type     TYPE c LENGTH 1,
        lv_len      TYPE i,
        lt_fld      TYPE STANDARD TABLE OF abap_compname,
        lv_fld      TYPE abap_compname,
        lv_key_date TYPE sy-datum,
        lv_mode     TYPE c LENGTH 1 VALUE 'C',
        lv_seq      TYPE c LENGTH 1 VALUE '0',
        lv_one      TYPE i VALUE 1,
        lx_dyn      TYPE REF TO cx_sy_dyn_call_error.

  FIELD-SYMBOLS: <lt_opr>  TYPE ANY TABLE,
                 <lt_oprx> TYPE ANY TABLE,
                 <ls_opr>  TYPE any,
                 <ls_oprx> TYPE any,
                 <lv_src>  TYPE any,
                 <lv_tgt>  TYPE any.

  CLEAR: cv_error, cv_success, ct_err.

*----------------------------------------------------------------------*
* Import parameters
*----------------------------------------------------------------------*
  lv_key_date = sy-datum.
  PERFORM bind_import USING 'KEY_DATE'        lv_key_date     CHANGING lt_ptab.
  PERFORM bind_import USING 'TASK_LIST_GROUP' is_excel-plnnr  CHANGING lt_ptab.
  PERFORM bind_import USING 'GROUP_COUNTER'   is_excel-plnal  CHANGING lt_ptab.

*----------------------------------------------------------------------*
* Table OPERATIONS
*----------------------------------------------------------------------*
  PERFORM create_table_param USING gc_par_opr  CHANGING lr_opr  lv_kind  lv_fail.
  PERFORM create_table_param USING gc_par_oprx CHANGING lr_oprx lv_kindx lv_failx.
  IF lv_fail = abap_true OR lv_failx = abap_true.
    cv_error = abap_true.
    lv_text  = |Interface of Function Module { gc_fm_name } could not be determined.|.
    APPEND lv_text TO ct_err.
    RETURN.
  ENDIF.

  ASSIGN lr_opr->* TO <lt_opr>.
  CREATE DATA lr_line LIKE LINE OF <lt_opr>.
  ASSIGN lr_line->* TO <ls_opr>.

  PERFORM set_comp USING 'MAINTAIN_MODE'              lv_mode          CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'SEQUENCE_NO'                lv_seq           CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'ACTIVITY'                   iv_vornr         CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'CONTROL_KEY'                is_excel-steus   CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'WORK_CNTR'                  is_excel-arbpl   CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'PLANT'                      is_excel-werks   CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'DESCRIPTION'                is_excel-ltxa1   CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'OPERATION_MEASURE_UNIT'     is_excel-meinh   CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'OPERATION_MEASURE_UNIT_ISO' iv_iso           CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'DENOMINATOR'                lv_one           CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'NOMINATOR'                  lv_one           CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'BASE_QUANTITY'              is_excel-bmsch   CHANGING <ls_opr> lv_missing.
  PERFORM set_comp USING 'STD_VALUE_01'               is_excel-vgw01   CHANGING <ls_opr> lv_missing.

  INSERT <ls_opr> INTO TABLE <lt_opr>.

*----------------------------------------------------------------------*
* Table OPERATIONS_X
*----------------------------------------------------------------------*
  ASSIGN lr_oprx->* TO <lt_oprx>.
  CREATE DATA lr_linex LIKE LINE OF <lt_oprx>.
  ASSIGN lr_linex->* TO <ls_oprx>.

* Key-type fields: copied with their value if present in the _X structure
  ASSIGN COMPONENT 'MAINTAIN_MODE' OF STRUCTURE <ls_oprx> TO <lv_tgt>.
  IF sy-subrc = 0.
    <lv_tgt> = lv_mode.
  ENDIF.
  ASSIGN COMPONENT 'SEQUENCE_NO' OF STRUCTURE <ls_oprx> TO <lv_tgt>.
  IF sy-subrc = 0.
    <lv_tgt> = lv_seq.
  ENDIF.

* Update flags as per FS
  APPEND 'ACTIVITY'                   TO lt_fld.
  APPEND 'CONTROL_KEY'                TO lt_fld.
  APPEND 'WORK_CNTR'                  TO lt_fld.
  APPEND 'PLANT'                      TO lt_fld.
  APPEND 'DESCRIPTION'                TO lt_fld.
  APPEND 'OPERATION_MEASURE_UNIT'     TO lt_fld.
  APPEND 'OPERATION_MEASURE_UNIT_ISO' TO lt_fld.
  APPEND 'DENOMINATOR'                TO lt_fld.
  APPEND 'NOMINATOR'                  TO lt_fld.
  APPEND 'BASE_QUANTITY'              TO lt_fld.
  APPEND 'STD_VALUE_01'               TO lt_fld.

  LOOP AT lt_fld INTO lv_fld.
    ASSIGN COMPONENT lv_fld OF STRUCTURE <ls_oprx> TO <lv_tgt>.
    IF sy-subrc <> 0.
      lv_missing = |{ lv_missing } { lv_fld }(_X)|.
      CONTINUE.
    ENDIF.
    CLEAR: lv_type, lv_len.
    DESCRIBE FIELD <lv_tgt> TYPE lv_type.
    IF lv_type = 'C'.
      DESCRIBE FIELD <lv_tgt> LENGTH lv_len IN CHARACTER MODE.
    ENDIF.
    IF lv_type = 'C' AND lv_len = 1.
      <lv_tgt> = abap_true.                      " Update flag 'X'
    ELSE.
*     Non-flag field in _X (key field) => pass the value itself
      ASSIGN COMPONENT lv_fld OF STRUCTURE <ls_opr> TO <lv_src>.
      IF sy-subrc = 0.
        <lv_tgt> = <lv_src>.
      ENDIF.
    ENDIF.
  ENDLOOP.

  INSERT <ls_oprx> INTO TABLE <lt_oprx>.

  IF lv_missing IS NOT INITIAL.
    cv_error = abap_true.
    lv_text  = |Interface of Function Module { gc_fm_name } does not match. Missing field(s):{ lv_missing }.|.
    APPEND lv_text TO ct_err.
    RETURN.
  ENDIF.

  ls_pbind-name  = gc_par_opr.
  ls_pbind-kind  = lv_kind.
  ls_pbind-value = lr_opr.
  INSERT ls_pbind INTO TABLE lt_ptab.

  ls_pbind-name  = gc_par_oprx.
  ls_pbind-kind  = lv_kindx.
  ls_pbind-value = lr_oprx.
  INSERT ls_pbind INTO TABLE lt_ptab.

*----------------------------------------------------------------------*
* All other export / tables parameters (to receive return messages)
*----------------------------------------------------------------------*
  LOOP AT gt_fmpar INTO ls_fmpar WHERE paramtype = 'E' OR paramtype = 'T'.
    READ TABLE lt_ptab TRANSPORTING NO FIELDS
      WITH TABLE KEY name = ls_fmpar-parameter.
    IF sy-subrc = 0.
      CONTINUE.
    ENDIF.
    CLEAR ls_out.
    IF ls_fmpar-paramtype = 'T'.
      PERFORM create_table_param USING ls_fmpar-parameter
                                 CHANGING ls_out-ref lv_kind lv_fail.
      IF lv_fail = abap_true.
        CONTINUE.
      ENDIF.
    ELSE.
      PERFORM create_elem_param USING ls_fmpar-structure CHANGING ls_out-ref.
      IF ls_out-ref IS NOT BOUND.
        CONTINUE.
      ENDIF.
      lv_kind = abap_func_importing.
    ENDIF.
    ls_out-name = ls_fmpar-parameter.
    APPEND ls_out TO lt_out.

    ls_pbind-name  = ls_fmpar-parameter.
    ls_pbind-kind  = lv_kind.
    ls_pbind-value = ls_out-ref.
    INSERT ls_pbind INTO TABLE lt_ptab.
  ENDLOOP.

*----------------------------------------------------------------------*
* Exceptions
*----------------------------------------------------------------------*
  ls_ebind-name  = 'ERROR_MESSAGE'.
  ls_ebind-value = 98.
  INSERT ls_ebind INTO TABLE lt_etab.
  ls_ebind-name  = 'OTHERS'.
  ls_ebind-value = 99.
  INSERT ls_ebind INTO TABLE lt_etab.

*----------------------------------------------------------------------*
* Call FM
*----------------------------------------------------------------------*
  CLEAR: sy-msgid, sy-msgty, sy-msgno, sy-msgv1, sy-msgv2, sy-msgv3, sy-msgv4.

  TRY.
      CALL FUNCTION gc_fm_name
        PARAMETER-TABLE lt_ptab
        EXCEPTION-TABLE lt_etab.
      lv_subrc = sy-subrc.
    CATCH cx_sy_dyn_call_error INTO lx_dyn.
      cv_error = abap_true.
      lv_text  = lx_dyn->get_text( ).
      APPEND lv_text TO ct_err.
      RETURN.
  ENDTRY.

  IF lv_subrc <> 0.
    cv_error = abap_true.
    IF sy-msgid IS NOT INITIAL.
      MESSAGE ID sy-msgid TYPE 'S' NUMBER sy-msgno
        WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4 INTO lv_text.
    ELSE.
      lv_text = |Function Module { gc_fm_name } raised an exception (sy-subrc { lv_subrc }).|.
    ENDIF.
    APPEND lv_text TO ct_err.
  ENDIF.

* Return messages
  LOOP AT lt_out INTO ls_out.
    PERFORM collect_messages USING ls_out-ref CHANGING ct_err cv_success.
  ENDLOOP.

  IF ct_err IS NOT INITIAL.
    cv_error = abap_true.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form BIND_IMPORT
*&---------------------------------------------------------------------*
FORM bind_import USING    iv_name  TYPE abap_parmname
                          iv_value TYPE any
                 CHANGING ct_ptab  TYPE abap_func_parmbind_tab.

  DATA: ls_pbind TYPE abap_func_parmbind,
        ls_fmpar TYPE ty_fmpar,
        lo_type  TYPE REF TO cl_abap_typedescr,
        lo_data  TYPE REF TO cl_abap_datadescr.

  FIELD-SYMBOLS: <lv_val> TYPE any.

  READ TABLE gt_fmpar INTO ls_fmpar WITH KEY parameter = iv_name.
  IF sy-subrc = 0 AND ls_fmpar-structure IS NOT INITIAL.
    cl_abap_typedescr=>describe_by_name(
      EXPORTING
        p_name         = ls_fmpar-structure
      RECEIVING
        p_descr_ref    = lo_type
      EXCEPTIONS
        type_not_found = 1
        OTHERS         = 2 ).
    IF sy-subrc = 0 AND lo_type IS BOUND.
      TRY.
          lo_data ?= lo_type.
        CATCH cx_sy_move_cast_error.
          CLEAR lo_data.
      ENDTRY.
    ENDIF.
  ENDIF.

* Use the FM's own parameter type where possible
  IF lo_data IS BOUND.
    CREATE DATA ls_pbind-value TYPE HANDLE lo_data.
  ELSE.
    CREATE DATA ls_pbind-value LIKE iv_value.
  ENDIF.
  ASSIGN ls_pbind-value->* TO <lv_val>.
  <lv_val> = iv_value.

  ls_pbind-name = iv_name.
  ls_pbind-kind = abap_func_exporting.
  INSERT ls_pbind INTO TABLE ct_ptab.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form CREATE_TABLE_PARAM
*&---------------------------------------------------------------------*
FORM create_table_param USING    iv_name  TYPE abap_parmname
                        CHANGING cr_data  TYPE REF TO data
                                 cv_kind  TYPE i
                                 cv_error TYPE abap_bool.

  DATA: ls_fmpar TYPE ty_fmpar,
        lo_type  TYPE REF TO cl_abap_typedescr.

  CLEAR: cr_data, cv_kind, cv_error.

  READ TABLE gt_fmpar INTO ls_fmpar WITH KEY parameter = iv_name.
  IF sy-subrc <> 0 OR ls_fmpar-structure IS INITIAL.
    cv_error = abap_true.
    RETURN.
  ENDIF.

  cl_abap_typedescr=>describe_by_name(
    EXPORTING
      p_name         = ls_fmpar-structure
    RECEIVING
      p_descr_ref    = lo_type
    EXCEPTIONS
      type_not_found = 1
      OTHERS         = 2 ).
  IF sy-subrc <> 0 OR lo_type IS NOT BOUND.
    cv_error = abap_true.
    RETURN.
  ENDIF.

  TRY.
      IF lo_type->kind = cl_abap_typedescr=>kind_table.
        CREATE DATA cr_data TYPE (ls_fmpar-structure).
      ELSE.
        CREATE DATA cr_data TYPE STANDARD TABLE OF (ls_fmpar-structure).
      ENDIF.
    CATCH cx_sy_create_data_error.
      cv_error = abap_true.
      RETURN.
  ENDTRY.

  CASE ls_fmpar-paramtype.
    WHEN 'T'. cv_kind = abap_func_tables.
    WHEN 'I'. cv_kind = abap_func_exporting.
    WHEN 'E'. cv_kind = abap_func_importing.
    WHEN 'C'. cv_kind = abap_func_changing.
    WHEN OTHERS.
      cv_error = abap_true.
  ENDCASE.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form CREATE_ELEM_PARAM
*&---------------------------------------------------------------------*
FORM create_elem_param USING    iv_type_name TYPE fupararef-structure
                       CHANGING cr_data      TYPE REF TO data.

  DATA: lo_type TYPE REF TO cl_abap_typedescr,
        lo_data TYPE REF TO cl_abap_datadescr.

  CLEAR cr_data.
  IF iv_type_name IS INITIAL.
    RETURN.
  ENDIF.

  cl_abap_typedescr=>describe_by_name(
    EXPORTING
      p_name         = iv_type_name
    RECEIVING
      p_descr_ref    = lo_type
    EXCEPTIONS
      type_not_found = 1
      OTHERS         = 2 ).
  IF sy-subrc <> 0 OR lo_type IS NOT BOUND.
    RETURN.
  ENDIF.

  TRY.
      lo_data ?= lo_type.
      CREATE DATA cr_data TYPE HANDLE lo_data.
    CATCH cx_sy_move_cast_error cx_sy_create_data_error.
      CLEAR cr_data.
  ENDTRY.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form SET_COMP
*&---------------------------------------------------------------------*
FORM set_comp USING    iv_comp    TYPE c
                       iv_value   TYPE any
              CHANGING cs_line    TYPE any
                       cv_missing TYPE string.

  FIELD-SYMBOLS: <lv_comp> TYPE any.

  ASSIGN COMPONENT iv_comp OF STRUCTURE cs_line TO <lv_comp>.
  IF sy-subrc = 0.
    TRY.
        <lv_comp> = iv_value.
      CATCH cx_sy_conversion_error.
        cv_missing = |{ cv_missing } { iv_comp }(conversion)|.
    ENDTRY.
  ELSE.
    cv_missing = |{ cv_missing } { iv_comp }|.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form COLLECT_MESSAGES
*&---------------------------------------------------------------------*
FORM collect_messages USING    ir_data    TYPE REF TO data
                      CHANGING ct_err     TYPE string_table
                               cv_success TYPE string.

  DATA: lv_type TYPE c LENGTH 1.

  FIELD-SYMBOLS: <lv_any> TYPE any,
                 <lt_any> TYPE ANY TABLE,
                 <ls_any> TYPE any.

  IF ir_data IS NOT BOUND.
    RETURN.
  ENDIF.
  ASSIGN ir_data->* TO <lv_any>.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  DESCRIBE FIELD <lv_any> TYPE lv_type.
  IF lv_type = 'h'.                                   " Internal table
    ASSIGN <lv_any> TO <lt_any>.
    LOOP AT <lt_any> ASSIGNING <ls_any>.
      PERFORM read_message USING <ls_any> CHANGING ct_err cv_success.
    ENDLOOP.
  ELSEIF lv_type = 'u' OR lv_type = 'v'.              " Structure
    PERFORM read_message USING <lv_any> CHANGING ct_err cv_success.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form READ_MESSAGE
*&---------------------------------------------------------------------*
FORM read_message USING    is_msg     TYPE any
                  CHANGING ct_err     TYPE string_table
                           cv_success TYPE string.

  DATA: lv_msgty TYPE sy-msgty,
        lv_msgid TYPE sy-msgid,
        lv_msgno TYPE sy-msgno,
        lv_v1    TYPE sy-msgv1,
        lv_v2    TYPE sy-msgv2,
        lv_v3    TYPE sy-msgv3,
        lv_v4    TYPE sy-msgv4,
        lv_text  TYPE string.

  FIELD-SYMBOLS: <lv> TYPE any.

  TRY.
*     Message type (BAPIRET-like: TYPE, or MSGTY)
      ASSIGN COMPONENT 'TYPE' OF STRUCTURE is_msg TO <lv>.
      IF sy-subrc <> 0.
        ASSIGN COMPONENT 'MSGTY' OF STRUCTURE is_msg TO <lv>.
      ENDIF.
      IF sy-subrc <> 0.
        RETURN.
      ENDIF.
      lv_msgty = <lv>.
      IF lv_msgty IS INITIAL.
        RETURN.
      ENDIF.

*     Message text
      ASSIGN COMPONENT 'MESSAGE' OF STRUCTURE is_msg TO <lv>.
      IF sy-subrc = 0.
        lv_text = <lv>.
      ENDIF.

      IF lv_text IS INITIAL.
        ASSIGN COMPONENT 'ID' OF STRUCTURE is_msg TO <lv>.
        IF sy-subrc <> 0.
          ASSIGN COMPONENT 'MSGID' OF STRUCTURE is_msg TO <lv>.
        ENDIF.
        IF sy-subrc = 0.
          lv_msgid = <lv>.
        ENDIF.
        ASSIGN COMPONENT 'NUMBER' OF STRUCTURE is_msg TO <lv>.
        IF sy-subrc <> 0.
          ASSIGN COMPONENT 'MSGNO' OF STRUCTURE is_msg TO <lv>.
        ENDIF.
        IF sy-subrc = 0.
          lv_msgno = <lv>.
        ENDIF.
        ASSIGN COMPONENT 'MESSAGE_V1' OF STRUCTURE is_msg TO <lv>.
        IF sy-subrc <> 0.
          ASSIGN COMPONENT 'MSGV1' OF STRUCTURE is_msg TO <lv>.
        ENDIF.
        IF sy-subrc = 0.
          lv_v1 = <lv>.
        ENDIF.
        ASSIGN COMPONENT 'MESSAGE_V2' OF STRUCTURE is_msg TO <lv>.
        IF sy-subrc <> 0.
          ASSIGN COMPONENT 'MSGV2' OF STRUCTURE is_msg TO <lv>.
        ENDIF.
        IF sy-subrc = 0.
          lv_v2 = <lv>.
        ENDIF.
        ASSIGN COMPONENT 'MESSAGE_V3' OF STRUCTURE is_msg TO <lv>.
        IF sy-subrc <> 0.
          ASSIGN COMPONENT 'MSGV3' OF STRUCTURE is_msg TO <lv>.
        ENDIF.
        IF sy-subrc = 0.
          lv_v3 = <lv>.
        ENDIF.
        ASSIGN COMPONENT 'MESSAGE_V4' OF STRUCTURE is_msg TO <lv>.
        IF sy-subrc <> 0.
          ASSIGN COMPONENT 'MSGV4' OF STRUCTURE is_msg TO <lv>.
        ENDIF.
        IF sy-subrc = 0.
          lv_v4 = <lv>.
        ENDIF.
        IF lv_msgid IS NOT INITIAL.
          MESSAGE ID lv_msgid TYPE 'S' NUMBER lv_msgno
            WITH lv_v1 lv_v2 lv_v3 lv_v4 INTO lv_text.
        ENDIF.
      ENDIF.

    CATCH cx_sy_conversion_error.
      RETURN.
  ENDTRY.

  IF lv_text IS INITIAL.
    RETURN.
  ENDIF.

  CASE lv_msgty.
    WHEN 'E' OR 'A' OR 'X'.
      READ TABLE ct_err TRANSPORTING NO FIELDS WITH KEY table_line = lv_text.
      IF sy-subrc <> 0.
        APPEND lv_text TO ct_err.
      ENDIF.
    WHEN 'S' OR 'I'.
      IF cv_success IS INITIAL.
        cv_success = lv_text.
      ENDIF.
  ENDCASE.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form DISPLAY_LOG_ALV
*&---------------------------------------------------------------------*
FORM display_log_alv.

  DATA: lx_msg  TYPE REF TO cx_salv_msg,
        lx_nf   TYPE REF TO cx_salv_not_found,
        lx_data TYPE REF TO cx_salv_data_error.

  IF gt_log IS INITIAL.
    MESSAGE 'No data to display' TYPE 'S' DISPLAY LIKE 'I'.
    RETURN.
  ENDIF.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = go_alv
        CHANGING  t_table      = gt_log ).

      go_funcs = go_alv->get_functions( ).
      go_funcs->set_all( abap_true ).

      go_display = go_alv->get_display_settings( ).
      go_display->set_list_header( 'Change Routing: Output Log' ).
      go_display->set_striped_pattern( abap_true ).

      go_layout = go_alv->get_layout( ).
      gs_lkey-report = sy-repid.
      go_layout->set_key( gs_lkey ).
      go_layout->set_save_restriction( if_salv_c_layout=>restrict_none ).

      go_columns = go_alv->get_columns( ).
      go_columns->set_optimize( abap_true ).

      TRY.
          go_columns->set_color_column( 'T_COLOR' ).
        CATCH cx_salv_data_error INTO lx_data.
      ENDTRY.

      TRY.
          go_column = go_columns->get_column( 'SRNO' ).
          go_column->set_short_text( 'Sr. No.' ).
          go_column->set_medium_text( 'Sr. No.' ).
          go_column->set_long_text( 'Sr. No.' ).

          go_column = go_columns->get_column( 'LINE' ).
          go_column->set_short_text( 'Line' ).
          go_column->set_medium_text( 'Line' ).
          go_column->set_long_text( 'Line' ).

          go_column = go_columns->get_column( 'REMARKS' ).
          go_column->set_short_text( 'Remarks' ).
          go_column->set_medium_text( 'Remarks' ).
          go_column->set_long_text( 'Remarks' ).
          go_column->set_output_length( 100 ).

        CATCH cx_salv_not_found INTO lx_nf.
      ENDTRY.

      go_alv->display( ).

    CATCH cx_salv_msg INTO lx_msg.
      MESSAGE lx_msg TYPE 'E'.
  ENDTRY.

ENDFORM.

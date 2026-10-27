*&---------------------------------------------------------------------*
*& Include          ZFI_DMCC_TAX_INV_F01
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form INIT_DEFAULTS - internal team mail IDs from TVARVC
*&---------------------------------------------------------------------*
FORM init_defaults.
  DATA: lt_tvarvc TYPE STANDARD TABLE OF tvarvc,
        ls_tvarvc TYPE tvarvc.

  REFRESH s_email.
  SELECT * FROM tvarvc INTO TABLE lt_tvarvc
    WHERE name = gc_tvarv_mail
      AND type = 'S'.

  LOOP AT lt_tvarvc INTO ls_tvarvc WHERE low <> space.
    CLEAR s_email.
    s_email-sign   = 'I'.
    s_email-option = 'EQ'.
    s_email-low    = ls_tvarvc-low.
    APPEND s_email.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form MODIFY_SCREEN - e-mail field only for mail options
*&---------------------------------------------------------------------*
FORM modify_screen.
***BOC--UJWAL--27.10.2026 Phase 1: only Print is active.
* Mail options (RB_MINT / RB_MCUS) are greyed out until Phase 2.
* To activate later: delete the MOD ID MAL block below and the
* forced RB_PRNT in START-OF-SELECTION of ZFI_DMCC_TAX_INV.
  rb_prnt = 'X'.
  CLEAR: rb_mint, rb_mcus.
***EOC--UJWAL--27.10.2026

  LOOP AT SCREEN.
***BOC--UJWAL--27.10.2026
    IF screen-name = 'RB_MINT' OR screen-name = 'RB_MCUS'.
      screen-input = '0'.
      MODIFY SCREEN.
      CONTINUE.
    ENDIF.
***EOC--UJWAL--27.10.2026
    IF screen-group1 = 'EML'.
      IF rb_prnt = 'X'.
        screen-active = '0'.
      ELSE.
        screen-active = '1'.
      ENDIF.
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form VALIDATE_SELECTION
*&---------------------------------------------------------------------*
FORM validate_selection.
  DATA: lv_bukrs TYPE t001-bukrs,
        lv_msg   TYPE bapi_msg.

* Validate only on execute (not on radio button click)
  CHECK sscrfields-ucomm = 'ONLI'
     OR sscrfields-ucomm = 'PRIN'
     OR sscrfields-ucomm = 'SJOB'.

  SELECT SINGLE bukrs FROM t001 INTO lv_bukrs WHERE bukrs = p_bukrs.
  IF sy-subrc <> 0.
    MESSAGE 'Company code does not exist'(m40) TYPE 'E'.
  ENDIF.

  AUTHORITY-CHECK OBJECT 'F_BKPF_BUK'
           ID 'BUKRS' FIELD p_bukrs
           ID 'ACTVT' FIELD '03'.
  IF sy-subrc <> 0.
    MESSAGE 'No authorization for this company code'(m41) TYPE 'E'.
  ENDIF.

  IF rb_prnt IS INITIAL.
    IF s_email[] IS INITIAL.
      MESSAGE 'Enter at least one internal e-mail ID'(m42) TYPE 'E'.
    ENDIF.
    LOOP AT s_email.
      IF s_email-sign <> 'I' OR s_email-option <> 'EQ'
         OR s_email-low NA '@'.
        CONCATENATE 'Invalid e-mail ID:'(m43) s_email-low
               INTO lv_msg SEPARATED BY space.
        MESSAGE lv_msg TYPE 'E'.
      ENDIF.
    ENDLOOP.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_DATA
*&---------------------------------------------------------------------*
FORM get_data.

  SELECT bukrs belnr gjahr blart budat xblnr waers hwaer hwae2 hwae3
    FROM bkpf
    INTO TABLE gt_bkpf
    WHERE bukrs = p_bukrs
      AND belnr IN s_belnr
      AND gjahr = p_gjahr.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.
  SORT gt_bkpf BY bukrs belnr gjahr.

  SELECT bukrs belnr gjahr buzei buzid koart shkzg mwskz
         wrbtr dmbtr dmbe2 dmbe3 sgtxt kunnr lifnr rebzg rebzj
    FROM bseg
    INTO TABLE gt_bseg
    FOR ALL ENTRIES IN gt_bkpf
    WHERE bukrs = gt_bkpf-bukrs
      AND belnr = gt_bkpf-belnr
      AND gjahr = gt_bkpf-gjahr.
  SORT gt_bseg BY bukrs belnr gjahr buzei.

* Supplier details (own company code) - read once
  SELECT SINGLE bukrs butxt land1 adrnr stceg
    FROM t001
    INTO gs_t001
    WHERE bukrs = p_bukrs.

  PERFORM build_address USING gs_t001-adrnr CHANGING gv_comp_addr.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_FM_NAME
*&---------------------------------------------------------------------*
FORM get_fm_name.
  CALL FUNCTION 'SSF_FUNCTION_MODULE_NAME'
    EXPORTING
      formname           = gc_formname
    IMPORTING
      fm_name            = gv_fm_name
    EXCEPTIONS
      no_form            = 1
      no_function_module = 2
      OTHERS             = 3.
  IF sy-subrc <> 0.
    MESSAGE 'Smartform ZDMCC_FI_DOC is not active'(m11)
            TYPE 'S' DISPLAY LIKE 'E'.
    LEAVE LIST-PROCESSING.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_ALL - prepare form data for every document
*&---------------------------------------------------------------------*
FORM build_all.
  DATA: ls_bkpf  TYPE ty_bkpf,
        ls_out   TYPE ty_out,
        lv_subrc TYPE sysubrc,
        lv_msg   TYPE bapi_msg,
        lv_icon  TYPE icon_d.

  LOOP AT gt_bkpf INTO ls_bkpf.
    CLEAR: ls_out, lv_msg, lv_subrc.

    PERFORM build_document USING    ls_bkpf
                           CHANGING ls_out lv_subrc lv_msg.

    IF lv_subrc = 0.
      APPEND ls_out TO gt_out.
    ELSE.
      lv_icon = icon_red_light.
      PERFORM add_log USING ls_bkpf-bukrs ls_bkpf-belnr ls_bkpf-gjahr
                            ls_bkpf-blart lv_icon lv_msg.
    ENDIF.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_DOCUMENT - complete logic for one FI document
*&---------------------------------------------------------------------*
FORM build_document USING    is_bkpf  TYPE ty_bkpf
                    CHANGING cs_out   TYPE ty_out
                             cv_subrc TYPE sysubrc
                             cv_msg   TYPE bapi_msg.

  DATA: lt_doc      TYPE ty_t_bseg,
        ls_bseg     TYPE ty_bseg,
        ls_dk       TYPE ty_bseg,
        lt_calc     TYPE ty_t_calc,
        ls_calc     TYPE ty_calc,
        ls_itm      TYPE zst_dmcc_fi_itm,
        lv_tabix    TYPE sytabix,
        lv_koart    TYPE koart,
        lv_found    TYPE c LENGTH 1,
        lv_taxline  TYPE c LENGTH 1,
        lv_sign     TYPE i,
        lv_slno     TYPE i,
        lv_rc       TYPE sysubrc,
        lv_rate     TYPE ty_pct,
        lv_calc     TYPE p LENGTH 16 DECIMALS 6,
        lv_amt      TYPE bseg-wrbtr,
        lv_grs1     TYPE bseg-wrbtr,
        lv_grs2     TYPE bseg-wrbtr,
        lv_vatp1    TYPE bseg-wrbtr,
        lv_vatp2    TYPE bseg-wrbtr,
        lv_sum_amt1 TYPE bseg-wrbtr,
        lv_sum_vat1 TYPE bseg-wrbtr,
        lv_sum_amt2 TYPE bseg-wrbtr,
        lv_sum_vat2 TYPE bseg-wrbtr,
        lv_chk      TYPE bseg-wrbtr,
        lv_rebzg    TYPE bseg-rebzg,
        lv_rebzj    TYPE bseg-rebzj,
        lv_orig_ref TYPE bkpf-xblnr.

  cv_subrc = 4.

*----------------------------------------------------------------------*
* 1. Title + partner type from document type (BKPF-BLART = BSEG-H_BLART)
*----------------------------------------------------------------------*
  CASE is_bkpf-blart.
    WHEN 'DG'.
      cs_out-hdr-title = 'TAX CREDIT NOTE'(t01).
      lv_koart = gc_koart_cust.
    WHEN 'DR'.
      cs_out-hdr-title = 'TAX INVOICE'(t02).
      lv_koart = gc_koart_cust.
    WHEN 'KR'.
      cs_out-hdr-title = 'TAX INVOICE'(t02).
      lv_koart = gc_koart_vend.
    WHEN 'KG'.
      cs_out-hdr-title = 'TAX DEBIT NOTE'(t03).
      lv_koart = gc_koart_vend.
    WHEN OTHERS.
      CONCATENATE 'Document type'(m01) is_bkpf-blart
                  'is not relevant (only DR/DG/KR/KG)'(m02)
             INTO cv_msg SEPARATED BY space.
      RETURN.
  ENDCASE.

*----------------------------------------------------------------------*
* 2. Collect BSEG lines of this document
*----------------------------------------------------------------------*
  READ TABLE gt_bseg TRANSPORTING NO FIELDS
       WITH KEY bukrs = is_bkpf-bukrs
                belnr = is_bkpf-belnr
                gjahr = is_bkpf-gjahr
       BINARY SEARCH.
  IF sy-subrc <> 0.
    cv_msg = 'No line items found (parked/incomplete document)'(m03).
    RETURN.
  ENDIF.
  lv_tabix = sy-tabix.

  LOOP AT gt_bseg INTO ls_bseg FROM lv_tabix.
    IF ls_bseg-bukrs <> is_bkpf-bukrs
    OR ls_bseg-belnr <> is_bkpf-belnr
    OR ls_bseg-gjahr <> is_bkpf-gjahr.
      EXIT.
    ENDIF.
    APPEND ls_bseg TO lt_doc.
  ENDLOOP.

*----------------------------------------------------------------------*
* 3. Customer / vendor line(s): partner, reference, gross total
*----------------------------------------------------------------------*
  LOOP AT lt_doc INTO ls_bseg WHERE koart = lv_koart.
    IF lv_found IS INITIAL.
      ls_dk    = ls_bseg.
      lv_found = 'X'.
    ENDIF.

    IF lv_rebzg IS INITIAL AND ls_bseg-rebzg <> space.
      lv_rebzg = ls_bseg-rebzg.
      lv_rebzj = ls_bseg-rebzj.
    ENDIF.

    IF ls_bseg-shkzg = ls_dk-shkzg.
      lv_sign = 1.
    ELSE.
      lv_sign = -1.
    ENDIF.

    PERFORM get_amount USING is_bkpf ls_bseg gc_curr1
                       CHANGING lv_amt lv_rc.
    IF lv_rc <> 0.
      PERFORM set_conv_msg USING gc_curr1 CHANGING cv_msg.
      RETURN.
    ENDIF.
    lv_grs1 = lv_grs1 + lv_amt * lv_sign.

    PERFORM get_amount USING is_bkpf ls_bseg gc_curr2
                       CHANGING lv_amt lv_rc.
    IF lv_rc <> 0.
      PERFORM set_conv_msg USING gc_curr2 CHANGING cv_msg.
      RETURN.
    ENDIF.
    lv_grs2 = lv_grs2 + lv_amt * lv_sign.
  ENDLOOP.

  IF lv_found IS INITIAL.
    cv_msg = 'No customer/vendor line found in document'(m04).
    RETURN.
  ENDIF.

* Fallback: invoice reference on any other line
  IF lv_rebzg IS INITIAL.
    LOOP AT lt_doc INTO ls_bseg WHERE rebzg <> space.
      lv_rebzg = ls_bseg-rebzg.
      lv_rebzj = ls_bseg-rebzj.
      EXIT.
    ENDLOOP.
  ENDIF.

*----------------------------------------------------------------------*
* 4. Customer details (KNA1 / LFA1 / BSEC for one-time accounts)
*----------------------------------------------------------------------*
  PERFORM get_partner USING lv_koart ls_dk
                      CHANGING cs_out lv_rc cv_msg.
  IF lv_rc <> 0.
    RETURN.
  ENDIF.

*----------------------------------------------------------------------*
* 5. Header / supplier details
*----------------------------------------------------------------------*
  cs_out-hdr-bukrs      = is_bkpf-bukrs.
  cs_out-hdr-belnr      = is_bkpf-belnr.
  cs_out-hdr-gjahr      = is_bkpf-gjahr.
  cs_out-hdr-blart      = is_bkpf-blart.
  cs_out-hdr-inv_no     = is_bkpf-belnr.
  cs_out-hdr-comp_name  = gs_t001-butxt.
  cs_out-hdr-comp_taxno = gs_t001-stceg.
  cs_out-hdr-comp_addr  = gv_comp_addr.
  cs_out-hdr-curr1      = gc_curr1.
  cs_out-hdr-curr2      = gc_curr2.

  PERFORM get_posting_date USING is_bkpf CHANGING cs_out-hdr-inv_date.

*----------------------------------------------------------------------*
* 6. Original invoice reference (REBZG/REBZJ -> BKPF-XBLNR)
*----------------------------------------------------------------------*
  PERFORM get_orig_ref USING is_bkpf lv_rebzg lv_rebzj
                       CHANGING lv_orig_ref.

*----------------------------------------------------------------------*
* 7. Printable lines: KOART = 'S' and BUZID <> 'T'
*----------------------------------------------------------------------*
  LOOP AT lt_doc INTO ls_bseg WHERE koart = gc_koart_gl
                                AND buzid <> gc_buzid_tax.
    CLEAR ls_calc.

*   Revenue/expense lines are normally opposite to the D/K line.
*   Same side as D/K (e.g. discount line) => negative.
    IF ls_bseg-shkzg = ls_dk-shkzg.
      lv_sign = -1.
    ELSE.
      lv_sign = 1.
    ENDIF.

    PERFORM get_amount USING is_bkpf ls_bseg gc_curr1
                       CHANGING lv_amt lv_rc.
    IF lv_rc <> 0.
      PERFORM set_conv_msg USING gc_curr1 CHANGING cv_msg.
      RETURN.
    ENDIF.
    ls_calc-amt1 = lv_amt * lv_sign.

    PERFORM get_amount USING is_bkpf ls_bseg gc_curr2
                       CHANGING lv_amt lv_rc.
    IF lv_rc <> 0.
      PERFORM set_conv_msg USING gc_curr2 CHANGING cv_msg.
      RETURN.
    ENDIF.
    ls_calc-amt2 = lv_amt * lv_sign.

    PERFORM get_vat_rate USING ls_bseg-mwskz CHANGING lv_rate.
    ls_calc-rate  = lv_rate.
    ls_calc-sgtxt = ls_bseg-sgtxt.
    ls_calc-mwskz = ls_bseg-mwskz.

*   VAT = Amount x Rate / 100 (commercial rounding on move)
    lv_calc      = ls_calc-amt1 * lv_rate / 100.
    ls_calc-vat1 = lv_calc.
    lv_calc      = ls_calc-amt2 * lv_rate / 100.
    ls_calc-vat2 = lv_calc.

    APPEND ls_calc TO lt_calc.
  ENDLOOP.

  IF lt_calc IS INITIAL.
    cv_msg = 'No printable G/L line items in document'(m06).
    RETURN.
  ENDIF.

*----------------------------------------------------------------------*
* 8. Posted VAT (tax lines) -> absorb rounding difference
*----------------------------------------------------------------------*
  LOOP AT lt_doc INTO ls_bseg WHERE koart = gc_koart_gl
                                AND buzid = gc_buzid_tax.
    lv_taxline = 'X'.
    IF ls_bseg-shkzg = ls_dk-shkzg.
      lv_sign = -1.
    ELSE.
      lv_sign = 1.
    ENDIF.

    PERFORM get_amount USING is_bkpf ls_bseg gc_curr1
                       CHANGING lv_amt lv_rc.
    IF lv_rc <> 0.
      PERFORM set_conv_msg USING gc_curr1 CHANGING cv_msg.
      RETURN.
    ENDIF.
    lv_vatp1 = lv_vatp1 + lv_amt * lv_sign.

    PERFORM get_amount USING is_bkpf ls_bseg gc_curr2
                       CHANGING lv_amt lv_rc.
    IF lv_rc <> 0.
      PERFORM set_conv_msg USING gc_curr2 CHANGING cv_msg.
      RETURN.
    ENDIF.
    lv_vatp2 = lv_vatp2 + lv_amt * lv_sign.
  ENDLOOP.

  IF lv_taxline = 'X'.
    PERFORM reconcile_vat USING 'VAT1' lv_vatp1 gc_curr1
                          CHANGING lt_calc cs_out-warn.
    PERFORM reconcile_vat USING 'VAT2' lv_vatp2 gc_curr2
                          CHANGING lt_calc cs_out-warn.
  ENDIF.

*----------------------------------------------------------------------*
* 9. Final printable items (all formatted for the smartform)
*----------------------------------------------------------------------*
  LOOP AT lt_calc INTO ls_calc.
    CLEAR ls_itm.
    lv_slno = lv_slno + 1.
    WRITE lv_slno TO ls_itm-slno LEFT-JUSTIFIED.

    ls_itm-orig_ref = lv_orig_ref.
    ls_itm-sgtxt    = ls_calc-sgtxt.
    ls_itm-mwskz    = ls_calc-mwskz.

    PERFORM format_rate USING ls_calc-rate CHANGING ls_itm-vat_pct.

    PERFORM format_amount USING ls_calc-amt1 gc_curr1
                          CHANGING ls_itm-amt_c1.
    PERFORM format_amount USING ls_calc-vat1 gc_curr1
                          CHANGING ls_itm-vat_c1.
    lv_amt = ls_calc-amt1 + ls_calc-vat1.
    PERFORM format_amount USING lv_amt gc_curr1
                          CHANGING ls_itm-tot_c1.

    PERFORM format_amount USING ls_calc-amt2 gc_curr2
                          CHANGING ls_itm-amt_c2.
    PERFORM format_amount USING ls_calc-vat2 gc_curr2
                          CHANGING ls_itm-vat_c2.
    lv_amt = ls_calc-amt2 + ls_calc-vat2.
    PERFORM format_amount USING lv_amt gc_curr2
                          CHANGING ls_itm-tot_c2.

    APPEND ls_itm TO cs_out-itm.

    lv_sum_amt1 = lv_sum_amt1 + ls_calc-amt1.
    lv_sum_vat1 = lv_sum_vat1 + ls_calc-vat1.
    lv_sum_amt2 = lv_sum_amt2 + ls_calc-amt2.
    lv_sum_vat2 = lv_sum_vat2 + ls_calc-vat2.
  ENDLOOP.

*----------------------------------------------------------------------*
* 10. Totals (TOTAL column = D/K line WRBTR as per spec) + in words
*----------------------------------------------------------------------*
  PERFORM format_amount USING lv_sum_amt1 gc_curr1
                        CHANGING cs_out-hdr-tot_amt_c1.
  PERFORM format_amount USING lv_sum_vat1 gc_curr1
                        CHANGING cs_out-hdr-tot_vat_c1.
  PERFORM format_amount USING lv_grs1 gc_curr1
                        CHANGING cs_out-hdr-tot_grs_c1.

  PERFORM format_amount USING lv_sum_amt2 gc_curr2
                        CHANGING cs_out-hdr-tot_amt_c2.
  PERFORM format_amount USING lv_sum_vat2 gc_curr2
                        CHANGING cs_out-hdr-tot_vat_c2.
  PERFORM format_amount USING lv_grs2 gc_curr2
                        CHANGING cs_out-hdr-tot_grs_c2.

  PERFORM amount_in_words USING lv_grs1 gc_curr1
                          CHANGING cs_out-hdr-words_c1.
  PERFORM amount_in_words USING lv_grs2 gc_curr2
                          CHANGING cs_out-hdr-words_c2.

* Consistency check: Sum(lines) + VAT must equal customer/vendor total
  lv_chk = lv_sum_amt1 + lv_sum_vat1 - lv_grs1.
  IF lv_chk <> 0.
    IF cs_out-warn IS INITIAL.
      cs_out-warn = 'Line total <> customer/vendor total'(m21).
    ELSE.
      CONCATENATE cs_out-warn '/' 'Line total <> customer/vendor total'(m21)
             INTO cs_out-warn SEPARATED BY space.
    ENDIF.
  ENDIF.

  cv_subrc = 0.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_PARTNER - Customer Details block
*&---------------------------------------------------------------------*
FORM get_partner USING    iv_koart TYPE koart
                          is_dk    TYPE ty_bseg
                 CHANGING cs_out   TYPE ty_out
                          cv_subrc TYPE sysubrc
                          cv_msg   TYPE bapi_msg.

  DATA: lv_name1 TYPE kna1-name1,
        lv_stceg TYPE kna1-stceg,
        lv_adrnr TYPE kna1-adrnr,
        lv_xcpdk TYPE kna1-xcpdk,
        lv_stras TYPE bsec-stras,
        lv_pstlz TYPE bsec-pstlz,
        lv_ort01 TYPE bsec-ort01,
        lv_addr  TYPE char255.

  cv_subrc = 4.

  IF iv_koart = gc_koart_cust.
    SELECT SINGLE name1 stceg adrnr xcpdk
      FROM kna1
      INTO (lv_name1, lv_stceg, lv_adrnr, lv_xcpdk)
      WHERE kunnr = is_dk-kunnr.
  ELSE.
    SELECT SINGLE name1 stceg adrnr xcpdk
      FROM lfa1
      INTO (lv_name1, lv_stceg, lv_adrnr, lv_xcpdk)
      WHERE lifnr = is_dk-lifnr.
  ENDIF.
  IF sy-subrc <> 0.
    cv_msg = 'Customer/vendor master not found'(m07).
    RETURN.
  ENDIF.

  IF lv_xcpdk = 'X'.
*   One-time customer/vendor: data is stored per document in BSEC
    SELECT SINGLE name1 stceg stras pstlz ort01
      FROM bsec
      INTO (lv_name1, lv_stceg, lv_stras, lv_pstlz, lv_ort01)
      WHERE bukrs = is_dk-bukrs
        AND belnr = is_dk-belnr
        AND gjahr = is_dk-gjahr
        AND buzei = is_dk-buzei.
    IF sy-subrc = 0.
      PERFORM concat_part USING lv_stras CHANGING lv_addr.
      PERFORM concat_part USING lv_pstlz CHANGING lv_addr.
      PERFORM concat_part USING lv_ort01 CHANGING lv_addr.
    ENDIF.
  ELSE.
    PERFORM build_address USING lv_adrnr CHANGING lv_addr.

    SELECT smtp_addr
      FROM adr6
      INTO TABLE cs_out-mail
      WHERE addrnumber = lv_adrnr
        AND persnumber = space.
    DELETE cs_out-mail WHERE table_line IS INITIAL.
    SORT cs_out-mail.
    DELETE ADJACENT DUPLICATES FROM cs_out-mail.
  ENDIF.

  cs_out-hdr-party_name  = lv_name1.
  cs_out-hdr-party_taxno = lv_stceg.
  cs_out-hdr-party_addr  = lv_addr.

  cv_subrc = 0.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_ADDRESS - ADRC: STREET+STR_SUPPL3+POST_CODE1+CITY1
*&---------------------------------------------------------------------*
FORM build_address USING    iv_adrnr TYPE adrnr
                   CHANGING cv_addr  TYPE char255.

  DATA: lv_street TYPE adrc-street,
        lv_suppl3 TYPE adrc-str_suppl3,
        lv_pcode  TYPE adrc-post_code1,
        lv_city   TYPE adrc-city1.

  CLEAR cv_addr.
  CHECK iv_adrnr IS NOT INITIAL.

  SELECT street str_suppl3 post_code1 city1
    FROM adrc
    INTO (lv_street, lv_suppl3, lv_pcode, lv_city)
    UP TO 1 ROWS
    WHERE addrnumber = iv_adrnr
      AND date_from <= sy-datum
      AND nation     = space
    ORDER BY date_from DESCENDING.
  ENDSELECT.
  CHECK sy-subrc = 0.

  PERFORM concat_part USING lv_street CHANGING cv_addr.
  PERFORM concat_part USING lv_suppl3 CHANGING cv_addr.
  PERFORM concat_part USING lv_pcode  CHANGING cv_addr.
  PERFORM concat_part USING lv_city   CHANGING cv_addr.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form CONCAT_PART - append non-blank part with ", "
*&---------------------------------------------------------------------*
FORM concat_part USING    iv_part TYPE c
                 CHANGING cv_addr TYPE char255.
  CHECK iv_part IS NOT INITIAL.
  IF cv_addr IS INITIAL.
    cv_addr = iv_part.
  ELSE.
    CONCATENATE cv_addr ',' INTO cv_addr.
    CONCATENATE cv_addr iv_part INTO cv_addr SEPARATED BY space.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_POSTING_DATE - ACDOCA-BUDAT (fallback BKPF-BUDAT)
*&---------------------------------------------------------------------*
FORM get_posting_date USING    is_bkpf  TYPE ty_bkpf
                      CHANGING cv_budat TYPE budat.
  DATA lv_budat TYPE acdoca-budat.

  SELECT budat
    FROM acdoca
    INTO lv_budat
    UP TO 1 ROWS
    WHERE rbukrs = is_bkpf-bukrs
      AND gjahr  = is_bkpf-gjahr
      AND belnr  = is_bkpf-belnr.
  ENDSELECT.

  IF sy-subrc = 0 AND lv_budat IS NOT INITIAL.
    cv_budat = lv_budat.
  ELSE.
    cv_budat = is_bkpf-budat.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_ORIG_REF - Original invoice reference no.
*&  REBZG filled  -> XBLNR of referenced document (BUKRS/REBZG/REBZJ)
*&  REBZG initial -> XBLNR of the document itself
*&---------------------------------------------------------------------*
FORM get_orig_ref USING    is_bkpf  TYPE ty_bkpf
                           iv_rebzg TYPE bseg-rebzg
                           iv_rebzj TYPE bseg-rebzj
                  CHANGING cv_ref   TYPE bkpf-xblnr.
  DATA: lv_gjahr TYPE bkpf-gjahr,
        lv_xblnr TYPE bkpf-xblnr.

  cv_ref = is_bkpf-xblnr.
  CHECK iv_rebzg IS NOT INITIAL.

  lv_gjahr = iv_rebzj.
  IF lv_gjahr IS INITIAL.
    lv_gjahr = is_bkpf-gjahr.
  ENDIF.

  SELECT SINGLE xblnr FROM bkpf INTO lv_xblnr
    WHERE bukrs = is_bkpf-bukrs
      AND belnr = iv_rebzg
      AND gjahr = lv_gjahr.
  IF sy-subrc = 0.
    cv_ref = lv_xblnr.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_AMOUNT - line amount in requested currency
*&  Uses posted amount if the currency is document/local/2nd/3rd
*&  currency of the document, otherwise converts from local currency
*&  at posting date (rate type M).
*&---------------------------------------------------------------------*
FORM get_amount USING    is_bkpf  TYPE ty_bkpf
                         is_bseg  TYPE ty_bseg
                         iv_waers TYPE waers
                CHANGING cv_amt   TYPE bseg-wrbtr
                         cv_subrc TYPE sysubrc.
  DATA lv_foreign TYPE bseg-wrbtr.

  CLEAR cv_amt.
  cv_subrc = 0.

  IF iv_waers = is_bkpf-waers.
    cv_amt = is_bseg-wrbtr.
  ELSEIF iv_waers = is_bkpf-hwaer.
    cv_amt = is_bseg-dmbtr.
  ELSEIF is_bkpf-hwae2 IS NOT INITIAL AND iv_waers = is_bkpf-hwae2.
    cv_amt = is_bseg-dmbe2.
  ELSEIF is_bkpf-hwae3 IS NOT INITIAL AND iv_waers = is_bkpf-hwae3.
    cv_amt = is_bseg-dmbe3.
  ELSE.
    CALL FUNCTION 'CONVERT_TO_FOREIGN_CURRENCY'
      EXPORTING
        date             = is_bkpf-budat
        foreign_currency = iv_waers
        local_amount     = is_bseg-dmbtr
        local_currency   = is_bkpf-hwaer
        type_of_rate     = 'M'
      IMPORTING
        foreign_amount   = lv_foreign
      EXCEPTIONS
        no_rate_found    = 1
        overflow         = 2
        no_factors_found = 3
        no_spread_found  = 4
        derived_2_times  = 5
        OTHERS           = 6.
    IF sy-subrc <> 0.
      cv_subrc = sy-subrc.
    ELSE.
      cv_amt = lv_foreign.
    ENDIF.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form SET_CONV_MSG
*&---------------------------------------------------------------------*
FORM set_conv_msg USING    iv_waers TYPE waers
                  CHANGING cv_msg   TYPE bapi_msg.
  CONCATENATE 'No exchange rate (type M) found for'(m05) iv_waers
         INTO cv_msg SEPARATED BY space.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_VAT_RATE - T001-LAND1 + MWSKZ -> A003 -> KONP-KBETR / 10
*&---------------------------------------------------------------------*
FORM get_vat_rate USING    iv_mwskz TYPE mwskz
                  CHANGING cv_rate  TYPE ty_pct.
  DATA: ls_rate  TYPE ty_rate,
        lt_cond  TYPE STANDARD TABLE OF ty_tax_cond,
        ls_cond  TYPE ty_tax_cond,
        lv_tabix TYPE sytabix.

  CLEAR cv_rate.
  CHECK iv_mwskz IS NOT INITIAL.

  READ TABLE gt_rate INTO ls_rate WITH KEY mwskz = iv_mwskz BINARY SEARCH.
  IF sy-subrc = 0.
    cv_rate = ls_rate-rate.
    RETURN.
  ENDIF.
  lv_tabix = sy-tabix.             " Insert position keeps table sorted

  CLEAR ls_rate.
  ls_rate-mwskz = iv_mwskz.

  SELECT a~knumh b~kbetr
    INTO TABLE lt_cond
    FROM a003 AS a
    INNER JOIN konp AS b ON b~knumh = a~knumh
    WHERE a~kappl    = gc_kappl_tx
      AND a~aland    = gs_t001-land1
      AND a~mwskz    = iv_mwskz
      AND b~loevm_ko = space.

  LOOP AT lt_cond INTO ls_cond WHERE kbetr <> 0.
*   KONP stores percentage in per mille (5% = 50) -> divide by 10
    ls_rate-rate = abs( ls_cond-kbetr ) / 10.
    EXIT.
  ENDLOOP.

  INSERT ls_rate INTO gt_rate INDEX lv_tabix.
  cv_rate = ls_rate-rate.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form RECONCILE_VAT - push rounding diff into last taxable line so
*&  that the VAT column adds up to the posted tax amount
*&---------------------------------------------------------------------*
FORM reconcile_vat USING    iv_comp   TYPE c
                            iv_posted TYPE bseg-wrbtr
                            iv_waers  TYPE waers
                   CHANGING ct_calc   TYPE ty_t_calc
                            cv_warn   TYPE bapi_msg.

  DATA: lv_sum  TYPE bseg-wrbtr,
        lv_diff TYPE bseg-wrbtr,
        lv_abs  TYPE bseg-wrbtr,
        lv_tol  TYPE bseg-wrbtr,
        lv_idx  TYPE sytabix,
        lv_txt  TYPE char30,
        lv_warn TYPE bapi_msg.
  FIELD-SYMBOLS: <ls_calc> TYPE ty_calc,
                 <lv_vat>  TYPE any.

  LOOP AT ct_calc ASSIGNING <ls_calc>.
    ASSIGN COMPONENT iv_comp OF STRUCTURE <ls_calc> TO <lv_vat>.
    lv_sum = lv_sum + <lv_vat>.
    IF <ls_calc>-rate <> 0.
      lv_idx = sy-tabix.
    ENDIF.
  ENDLOOP.

  lv_diff = iv_posted - lv_sum.
  CHECK lv_diff <> 0.

  lv_abs = abs( lv_diff ).
  lv_tol = lines( ct_calc ) * '0.01'.

  IF lv_abs <= lv_tol AND lv_idx > 0.
    READ TABLE ct_calc ASSIGNING <ls_calc> INDEX lv_idx.
    ASSIGN COMPONENT iv_comp OF STRUCTURE <ls_calc> TO <lv_vat>.
    <lv_vat> = <lv_vat> + lv_diff.
  ELSE.
    PERFORM format_amount USING lv_diff iv_waers CHANGING lv_txt.
    CONCATENATE 'Calculated VAT differs from posted VAT by'(m20) lv_txt
           INTO lv_warn SEPARATED BY space.
    IF cv_warn IS INITIAL.
      cv_warn = lv_warn.
    ELSE.
      CONCATENATE cv_warn '/' lv_warn INTO cv_warn SEPARATED BY space.
    ENDIF.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form FORMAT_AMOUNT - "AED 1,234.56" / "USD -336.11"
*&---------------------------------------------------------------------*
FORM format_amount USING    iv_amt   TYPE bseg-wrbtr
                            iv_waers TYPE waers
                   CHANGING cv_txt   TYPE c.
  DATA lv_txt TYPE char30.

  WRITE iv_amt TO lv_txt CURRENCY iv_waers LEFT-JUSTIFIED.
  CALL FUNCTION 'CLOI_PUT_SIGN_IN_FRONT'
    CHANGING
      value = lv_txt.
  CONDENSE lv_txt.
  CONCATENATE iv_waers lv_txt INTO cv_txt SEPARATED BY space.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form FORMAT_RATE - "5.00 %"
*&---------------------------------------------------------------------*
FORM format_rate USING    iv_rate TYPE ty_pct
                 CHANGING cv_txt  TYPE c.
  DATA lv_txt TYPE char15.

  WRITE iv_rate TO lv_txt DECIMALS 2 LEFT-JUSTIFIED.
  CONDENSE lv_txt.
  CONCATENATE lv_txt '%' INTO cv_txt SEPARATED BY space.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form AMOUNT_IN_WORDS
*&  "UAE DIRHAMS ONE THOUSAND FIFTY AND TWENTY FIVE FILS ONLY"
*&---------------------------------------------------------------------*
FORM amount_in_words USING    iv_amt   TYPE bseg-wrbtr
                              iv_waers TYPE waers
                     CHANGING cv_words TYPE c.
  DATA: ls_spell TYPE spell,
        lv_amt   TYPE bseg-wrbtr,
        lv_frac  TYPE bseg-wrbtr,
        lv_main  TYPE char40,
        lv_sub   TYPE char20.

  CLEAR cv_words.
  lv_amt = abs( iv_amt ).

  CASE iv_waers.
    WHEN 'AED'.
      lv_main = 'UAE DIRHAMS'(w01).
      lv_sub  = 'FILS'(w02).
    WHEN 'USD'.
      lv_main = 'US DOLLARS'(w03).
      lv_sub  = 'CENTS'(w04).
    WHEN OTHERS.
      lv_main = iv_waers.
      lv_sub  = 'CENTS'(w04).
  ENDCASE.

  CALL FUNCTION 'SPELL_AMOUNT'
    EXPORTING
      amount    = lv_amt
      currency  = iv_waers
      filler    = space
      language  = 'E'
    IMPORTING
      in_words  = ls_spell
    EXCEPTIONS
      not_found = 1
      too_large = 2
      OTHERS    = 3.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  CONCATENATE lv_main ls_spell-word INTO cv_words SEPARATED BY space.

  lv_frac = frac( lv_amt ).
  IF lv_frac <> 0.
    CONCATENATE cv_words 'AND'(w05) ls_spell-decword lv_sub
           INTO cv_words SEPARATED BY space.
  ENDIF.

  CONCATENATE cv_words 'ONLY'(w06) INTO cv_words SEPARATED BY space.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form OUTPUT_PRINT - all documents in one spool / preview
*&---------------------------------------------------------------------*
FORM output_print.
  DATA: ls_ctrl     TYPE ssfctrlop,
        ls_opt      TYPE ssfcompop,
        ls_job_info TYPE ssfcrescl,
        ls_out      TYPE ty_out,
        lv_subrc    TYPE sysubrc,
        lv_msg      TYPE bapi_msg.

  CHECK gt_out IS NOT INITIAL.

  ls_ctrl-no_dialog = space.
  ls_ctrl-preview   = space.

  CALL FUNCTION 'SSF_OPEN'
    EXPORTING
      user_settings      = 'X'
      output_options     = ls_opt
      control_parameters = ls_ctrl
    EXCEPTIONS
      formatting_error   = 1
      internal_error     = 2
      send_error         = 3
      user_canceled      = 4
      OTHERS             = 5.
  IF sy-subrc <> 0.
    lv_subrc = 4.
    IF sy-subrc = 4.
      lv_msg = 'Output cancelled by user'(m32).
    ELSE.
      lv_msg = 'Error opening smartform spool job'(m33).
    ENDIF.
    LOOP AT gt_out INTO ls_out.
      PERFORM log_out USING ls_out lv_subrc lv_msg.
    ENDLOOP.
    RETURN.
  ENDIF.

  ls_ctrl-no_open  = 'X'.
  ls_ctrl-no_close = 'X'.

  LOOP AT gt_out INTO ls_out.
    CALL FUNCTION gv_fm_name
      EXPORTING
        control_parameters = ls_ctrl
        output_options     = ls_opt
        user_settings      = space
        is_hdr             = ls_out-hdr
        it_itm             = ls_out-itm
      EXCEPTIONS
        formatting_error   = 1
        internal_error     = 2
        send_error         = 3
        user_canceled      = 4
        OTHERS             = 5.
    lv_subrc = sy-subrc.
    IF lv_subrc = 0.
      lv_msg = 'Sent to print/preview'(m30).
    ELSE.
      lv_msg = 'Smartform output error'(m31).
    ENDIF.
    PERFORM log_out USING ls_out lv_subrc lv_msg.
  ENDLOOP.

  CALL FUNCTION 'SSF_CLOSE'
    IMPORTING
      job_output_info  = ls_job_info
    EXCEPTIONS
      formatting_error = 1
      internal_error   = 2
      send_error       = 3
      OTHERS           = 4.
  IF sy-subrc <> 0.
    MESSAGE 'Error closing smartform spool job'(m34) TYPE 'S' DISPLAY LIKE 'E'.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form OUTPUT_MAIL - one PDF mail per document
*&  RB_MINT: To = internal IDs
*&  RB_MCUS: To = customer/vendor IDs (ADR6), CC = internal IDs
*&---------------------------------------------------------------------*
FORM output_mail.
  DATA: ls_ctrl     TYPE ssfctrlop,
        ls_opt      TYPE ssfcompop,
        ls_job_info TYPE ssfcrescl,
        lt_lines    TYPE STANDARD TABLE OF tline,
        lv_pdf      TYPE xstring,
        lv_size     TYPE i,
        ls_out      TYPE ty_out,
        lt_int      TYPE ty_t_mail,
        lt_to       TYPE ty_t_mail,
        lt_cc       TYPE ty_t_mail,
        lv_spld     TYPE usr01-spld,
        lv_subrc    TYPE sysubrc,
        lv_msg      TYPE bapi_msg.

  CHECK gt_out IS NOT INITIAL.

  LOOP AT s_email.
    APPEND s_email-low TO lt_int.
  ENDLOOP.
  SORT lt_int.
  DELETE ADJACENT DUPLICATES FROM lt_int.

  SELECT SINGLE spld FROM usr01 INTO lv_spld WHERE bname = sy-uname.
  IF lv_spld IS INITIAL.
    lv_spld = 'LOCL'.
  ENDIF.

  ls_ctrl-no_dialog = 'X'.
  ls_ctrl-preview   = space.
  ls_ctrl-getotf    = 'X'.
  ls_opt-tddest     = lv_spld.
  ls_opt-tdnoprev   = 'X'.

  LOOP AT gt_out INTO ls_out.
    REFRESH: lt_to, lt_cc, lt_lines.
    CLEAR: ls_job_info, lv_pdf, lv_size, lv_msg.

    IF rb_mint = 'X'.
      lt_to = lt_int.
    ELSE.
      IF ls_out-mail IS INITIAL.
        lv_subrc = 4.
        lv_msg = 'No e-mail ID maintained for customer/vendor'(m35).
        PERFORM log_out USING ls_out lv_subrc lv_msg.
        CONTINUE.
      ENDIF.
      lt_to = ls_out-mail.
      lt_cc = lt_int.
    ENDIF.

    CALL FUNCTION gv_fm_name
      EXPORTING
        control_parameters = ls_ctrl
        output_options     = ls_opt
        user_settings      = space
        is_hdr             = ls_out-hdr
        it_itm             = ls_out-itm
      IMPORTING
        job_output_info    = ls_job_info
      EXCEPTIONS
        formatting_error   = 1
        internal_error     = 2
        send_error         = 3
        user_canceled      = 4
        OTHERS             = 5.
    IF sy-subrc <> 0.
      lv_subrc = 4.
      lv_msg = 'Smartform output error'(m31).
      PERFORM log_out USING ls_out lv_subrc lv_msg.
      CONTINUE.
    ENDIF.

    CALL FUNCTION 'CONVERT_OTF'
      EXPORTING
        format                = 'PDF'
      IMPORTING
        bin_filesize          = lv_size
        bin_file              = lv_pdf
      TABLES
        otf                   = ls_job_info-otfdata
        lines                 = lt_lines
      EXCEPTIONS
        err_max_linewidth     = 1
        err_format            = 2
        err_conv_not_possible = 3
        err_bad_otf           = 4
        OTHERS                = 5.
    IF sy-subrc <> 0 OR lv_pdf IS INITIAL.
      lv_subrc = 4.
      lv_msg = 'PDF conversion failed'(m36).
      PERFORM log_out USING ls_out lv_subrc lv_msg.
      CONTINUE.
    ENDIF.

    PERFORM send_mail USING ls_out lv_pdf lt_to lt_cc
                      CHANGING lv_subrc lv_msg.
    PERFORM log_out USING ls_out lv_subrc lv_msg.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form SEND_MAIL - CL_BCS with PDF attachment
*&---------------------------------------------------------------------*
FORM send_mail USING    is_out   TYPE ty_out
                        iv_pdf   TYPE xstring
                        it_to    TYPE ty_t_mail
                        it_cc    TYPE ty_t_mail
               CHANGING cv_subrc TYPE sysubrc
                        cv_msg   TYPE bapi_msg.

  DATA: lo_send   TYPE REF TO cl_bcs,
        lo_doc    TYPE REF TO cl_document_bcs,
        lo_sender TYPE REF TO cl_sapuser_bcs,
        lo_rcpt   TYPE REF TO if_recipient_bcs,
        lx_bcs    TYPE REF TO cx_bcs,
        lt_body   TYPE soli_tab,
        ls_body   TYPE soli,
        lt_solix  TYPE solix_tab,
        lv_subj   TYPE so_obj_des,
        lv_att    TYPE so_obj_des,
        lv_size   TYPE so_obj_len,
        lv_mail   TYPE ad_smtpadr,
        lv_sent   TYPE os_boolean,
        lv_docno  TYPE char20,
        lv_date   TYPE char10,
        lv_title  TYPE string.

  cv_subrc = 4.
  CLEAR cv_msg.

  CONCATENATE is_out-hdr-belnr '/' is_out-hdr-gjahr INTO lv_docno.
  WRITE is_out-hdr-inv_date TO lv_date.

* Subject
  CONCATENATE is_out-hdr-title lv_docno '-' is_out-hdr-comp_name
         INTO lv_subj SEPARATED BY space.

* Attachment name e.g. TAX_INVOICE_1800000123_2026
  lv_title = is_out-hdr-title.
  REPLACE ALL OCCURRENCES OF ` ` IN lv_title WITH `_`.
  CONCATENATE lv_title '_' is_out-hdr-belnr '_' is_out-hdr-gjahr INTO lv_att.

* Body
  ls_body-line = 'Dear Sir/Madam,'(b01).
  APPEND ls_body TO lt_body.
  CLEAR ls_body.
  APPEND ls_body TO lt_body.
  CONCATENATE 'Please find attached'(b02) is_out-hdr-title 'No.'(b03)
              lv_docno 'dated'(b04) lv_date
         INTO ls_body-line SEPARATED BY space.
  APPEND ls_body TO lt_body.
  CLEAR ls_body.
  APPEND ls_body TO lt_body.
  ls_body-line = 'This is a system generated e-mail. Please do not reply.'(b05).
  APPEND ls_body TO lt_body.
  CLEAR ls_body.
  APPEND ls_body TO lt_body.
  ls_body-line = 'Regards,'(b06).
  APPEND ls_body TO lt_body.
  ls_body-line = is_out-hdr-comp_name.
  APPEND ls_body TO lt_body.

  TRY.
      lo_send = cl_bcs=>create_persistent( ).

      lo_doc = cl_document_bcs=>create_document(
                 i_type    = 'RAW'
                 i_text    = lt_body
                 i_subject = lv_subj ).

      lt_solix = cl_bcs_convert=>xstring_to_solix( iv_xstring = iv_pdf ).
      lv_size  = xstrlen( iv_pdf ).

      lo_doc->add_attachment(
        i_attachment_type    = 'PDF'
        i_attachment_subject = lv_att
        i_attachment_size    = lv_size
        i_att_content_hex    = lt_solix ).

      lo_send->set_document( lo_doc ).

      lo_sender = cl_sapuser_bcs=>create( sy-uname ).
      lo_send->set_sender( lo_sender ).

      LOOP AT it_to INTO lv_mail.
        lo_rcpt = cl_cam_address_bcs=>create_internet_address( lv_mail ).
        lo_send->add_recipient( i_recipient = lo_rcpt
                                i_express   = 'X' ).
      ENDLOOP.

      LOOP AT it_cc INTO lv_mail.
        lo_rcpt = cl_cam_address_bcs=>create_internet_address( lv_mail ).
        lo_send->add_recipient( i_recipient = lo_rcpt
                                i_express   = 'X'
                                i_copy      = 'X' ).
      ENDLOOP.

      lo_send->set_send_immediately( 'X' ).
      lv_sent = lo_send->send( i_with_error_screen = space ).

      IF lv_sent = 'X'.
        COMMIT WORK.
        cv_subrc = 0.
        cv_msg   = 'E-mail sent successfully'(m37).
      ELSE.
        ROLLBACK WORK.
        cv_msg   = 'E-mail could not be sent'(m38).
      ENDIF.

    CATCH cx_bcs INTO lx_bcs.
      ROLLBACK WORK.
      cv_msg = lx_bcs->get_text( ).
  ENDTRY.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form LOG_OUT - log entry for a prepared document
*&---------------------------------------------------------------------*
FORM log_out USING is_out   TYPE ty_out
                   iv_subrc TYPE sysubrc
                   iv_msg   TYPE bapi_msg.
  DATA: lv_icon TYPE icon_d,
        lv_msg  TYPE bapi_msg.

  lv_msg = iv_msg.
  IF iv_subrc <> 0.
    lv_icon = icon_red_light.
  ELSEIF is_out-warn IS NOT INITIAL.
    lv_icon = icon_yellow_light.
    CONCATENATE lv_msg '|' is_out-warn INTO lv_msg SEPARATED BY space.
  ELSE.
    lv_icon = icon_green_light.
  ENDIF.

  PERFORM add_log USING is_out-hdr-bukrs is_out-hdr-belnr is_out-hdr-gjahr
                        is_out-hdr-blart lv_icon lv_msg.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form ADD_LOG
*&---------------------------------------------------------------------*
FORM add_log USING iv_bukrs TYPE bukrs
                   iv_belnr TYPE belnr_d
                   iv_gjahr TYPE gjahr
                   iv_blart TYPE blart
                   iv_icon  TYPE icon_d
                   iv_msg   TYPE bapi_msg.
  DATA ls_log TYPE ty_log.

  ls_log-status  = iv_icon.
  ls_log-bukrs   = iv_bukrs.
  ls_log-belnr   = iv_belnr.
  ls_log-gjahr   = iv_gjahr.
  ls_log-blart   = iv_blart.
  ls_log-message = iv_msg.
  APPEND ls_log TO gt_log.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form DISPLAY_LOG - CL_SALV_TABLE
*&---------------------------------------------------------------------*
FORM display_log.
  DATA: lo_alv   TYPE REF TO cl_salv_table,
        lo_func  TYPE REF TO cl_salv_functions_list,
        lo_cols  TYPE REF TO cl_salv_columns_table,
        lo_col   TYPE REF TO cl_salv_column_table,
        lx_msg   TYPE REF TO cx_salv_msg,
        lx_nf    TYPE REF TO cx_salv_not_found,
        lv_text  TYPE string.

  CHECK gt_log IS NOT INITIAL.
  SORT gt_log BY bukrs gjahr belnr.

  TRY.
      cl_salv_table=>factory( IMPORTING r_salv_table = lo_alv
                              CHANGING  t_table      = gt_log ).

      lo_func = lo_alv->get_functions( ).
      lo_func->set_all( 'X' ).

      lo_cols = lo_alv->get_columns( ).
      lo_cols->set_optimize( 'X' ).

      TRY.
          lo_col ?= lo_cols->get_column( 'STATUS' ).
          lo_col->set_icon( 'X' ).
          lo_col->set_short_text( 'Status' ).
          lo_col->set_medium_text( 'Status' ).
          lo_col->set_long_text( 'Status' ).

          lo_col ?= lo_cols->get_column( 'MESSAGE' ).
          lo_col->set_short_text( 'Message' ).
          lo_col->set_medium_text( 'Message' ).
          lo_col->set_long_text( 'Message' ).
        CATCH cx_salv_not_found INTO lx_nf.
          lv_text = lx_nf->get_text( ).
      ENDTRY.

      lo_alv->display( ).

    CATCH cx_salv_msg INTO lx_msg.
      lv_text = lx_msg->get_text( ).
      MESSAGE lv_text TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.
ENDFORM.

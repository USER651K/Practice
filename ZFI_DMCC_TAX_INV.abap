*&---------------------------------------------------------------------*
*& Report      ZFI_DMCC_TAX_INV
*&---------------------------------------------------------------------*
*& Title       : Tax Invoice / Tax Debit Note / Tax Credit Note (DMCC)
*& Smartform   : ZDMCC_FI_DOC
*& Requirement : 3945 (Working_3945_logic.xlsx)
*& Author      : UJWAL
*& Date        : 27.10.2026
*& Description : Driver program. ALL data selection, business logic,
*&               currency conversion (AED/USD), VAT calculation,
*&               formatting and amount-in-words is done here. The
*&               smartform only prints the prepared fields.
*&               Output: Print / Mail internally / Mail party+internal
*&---------------------------------------------------------------------*
*& Change History
*& Date        Author   Description
*& 27.10.2026  UJWAL    Initial version
*&---------------------------------------------------------------------*
REPORT zfi_dmcc_tax_inv.

INCLUDE zfi_dmcc_tax_inv_top.     " Types, constants, global data
INCLUDE zfi_dmcc_tax_inv_sel.     " Selection screen
INCLUDE zfi_dmcc_tax_inv_f01.     " Form routines

*----------------------------------------------------------------------*
INITIALIZATION.
*----------------------------------------------------------------------*
  PERFORM init_defaults.

*----------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
*----------------------------------------------------------------------*
  PERFORM modify_screen.

*----------------------------------------------------------------------*
AT SELECTION-SCREEN.
*----------------------------------------------------------------------*
  PERFORM validate_selection.

*----------------------------------------------------------------------*
START-OF-SELECTION.
*----------------------------------------------------------------------*
***BOC--UJWAL--27.10.2026 Phase 1: force Print (covers variants/bg jobs)
  rb_prnt = 'X'.
  CLEAR: rb_mint, rb_mcus.
***EOC--UJWAL--27.10.2026

  PERFORM get_data.

  IF gt_bkpf IS INITIAL.
    MESSAGE 'No documents found for the given selection'(m10)
            TYPE 'S' DISPLAY LIKE 'E'.
    LEAVE LIST-PROCESSING.
  ENDIF.

  PERFORM get_fm_name.
  PERFORM build_all.

  IF rb_prnt = 'X'.
    PERFORM output_print.
  ELSE.
    PERFORM output_mail.
  ENDIF.

  PERFORM display_log.

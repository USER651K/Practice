*&---------------------------------------------------------------------*
*& Include          ZFI_DMCC_TAX_INV_SEL
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE text-s01.
PARAMETERS:     p_bukrs TYPE bkpf-bukrs OBLIGATORY.            " Single
SELECT-OPTIONS: s_belnr FOR gv_belnr    OBLIGATORY.            " Multiple
PARAMETERS:     p_gjahr TYPE bkpf-gjahr OBLIGATORY.            " Single
SELECTION-SCREEN END OF BLOCK b1.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE text-s02.
PARAMETERS: rb_prnt RADIOBUTTON GROUP rg1 DEFAULT 'X' USER-COMMAND ucom,
            rb_mint RADIOBUTTON GROUP rg1,
            rb_mcus RADIOBUTTON GROUP rg1.
SELECT-OPTIONS: s_email FOR gv_email NO INTERVALS LOWER CASE MODIF ID eml.
SELECTION-SCREEN END OF BLOCK b2.
